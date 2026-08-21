package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/github.com/labstack/echo/otelecho"

	"github.com/raflyritonga/tasklog/app/api/demo"
	"github.com/raflyritonga/tasklog/app/api/health"
	"github.com/raflyritonga/tasklog/app/api/obs"
	"github.com/raflyritonga/tasklog/app/api/report"
	"github.com/raflyritonga/tasklog/app/api/task"
)

var version = "dev"

func main() {
	cfg := loadConfig()
	logger := obs.NewLogger("tasklog-api")
	slog.SetDefault(logger)

	ctx := context.Background()
	otelShutdown, err := obs.Setup(ctx, cfg.otlpEndpoint, version)
	if err != nil {
		logger.Error("otel setup failed", "err", err.Error())
		os.Exit(1)
	}

	dbConfig, err := pgxpool.ParseConfig(cfg.databaseURL)
	if err != nil {
		logger.Error("invalid database url", "err", err.Error())
		os.Exit(1)
	}
	dbConfig.ConnConfig.Tracer = otelpgx.NewTracer()
	db, err := pgxpool.NewWithConfig(ctx, dbConfig)
	if err != nil {
		logger.Error("postgres pool setup failed", "err", err.Error())
		os.Exit(1)
	}

	rdb := redis.NewClient(&redis.Options{Addr: cfg.redisAddr})
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		logger.Warn("redis tracing instrumentation failed", "err", err.Error())
	}

	levers := &demo.Levers{}

	e := echo.New()
	e.HideBanner = true
	e.HidePort = true
	e.Use(otelecho.Middleware("tasklog-api"))
	e.Use(obs.Metrics())
	e.Use(obs.RequestLogger(logger))
	e.Use(demo.Middleware(levers))

	health.NewHandler(db, rdb).Register(e)
	api := e.Group("/api")
	task.NewHandler(task.NewStore(db, rdb)).Register(api)
	report.NewHandler(db).Register(api)
	demo.NewHandler(levers, logger).Register(api)

	go func() {
		logger.Info("tasklog-api listening", "port", cfg.port, "version", version)
		if err := e.Start(":" + cfg.port); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err.Error())
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := e.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown failed", "err", err.Error())
	}
	db.Close()
	rdb.Close()
	if err := otelShutdown(shutdownCtx); err != nil {
		logger.Error("otel shutdown failed", "err", err.Error())
	}
}
