package demo

import (
	"crypto/sha256"
	"log/slog"
	"math"
	"math/rand/v2"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/labstack/echo/v4"
)

type Levers struct {
	latencyMs atomic.Int64
	errorRate atomic.Uint64
	cpuMs     atomic.Int64
}

func (l *Levers) LatencyMs() int64 {
	return l.latencyMs.Load()
}

func (l *Levers) SetLatencyMs(ms int64) {
	l.latencyMs.Store(ms)
}

func (l *Levers) ErrorRate() float64 {
	return math.Float64frombits(l.errorRate.Load())
}

func (l *Levers) SetErrorRate(rate float64) {
	l.errorRate.Store(math.Float64bits(rate))
}

func (l *Levers) CPUMs() int64 {
	return l.cpuMs.Load()
}

func (l *Levers) SetCPUMs(ms int64) {
	l.cpuMs.Store(ms)
}

type state struct {
	LatencyMs int64   `json:"latency_ms"`
	ErrorRate float64 `json:"error_rate"`
	CPUMs     int64   `json:"cpu_ms"`
}

func (l *Levers) currentState() state {
	return state{LatencyMs: l.LatencyMs(), ErrorRate: l.ErrorRate(), CPUMs: l.CPUMs()}
}

func burn(ms int64) {
	sum := sha256.Sum256([]byte("tasklog"))
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	for time.Now().Before(deadline) {
		for range 1024 {
			sum = sha256.Sum256(sum[:])
		}
	}
}

func Middleware(l *Levers) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			if strings.HasPrefix(c.Request().URL.Path, "/api/tasks") {
				if ms := l.LatencyMs(); ms > 0 {
					time.Sleep(time.Duration(ms) * time.Millisecond)
				}
				if ms := l.CPUMs(); ms > 0 {
					burn(ms)
				}
				if rate := l.ErrorRate(); rate > 0 && rand.Float64() < rate {
					return echo.NewHTTPError(http.StatusInternalServerError, "injected error")
				}
			}
			return next(c)
		}
	}
}

type Handler struct {
	levers *Levers
	logger *slog.Logger
}

func NewHandler(levers *Levers, logger *slog.Logger) *Handler {
	return &Handler{levers: levers, logger: logger}
}

func (h *Handler) Register(g *echo.Group) {
	g.GET("/demo", h.state)
	g.POST("/demo/latency", h.latency)
	g.POST("/demo/errors", h.errors)
	g.POST("/demo/cpu", h.cpu)
	g.POST("/demo/reset", h.reset)
}

func (h *Handler) state(c echo.Context) error {
	return c.JSON(http.StatusOK, h.levers.currentState())
}

func (h *Handler) latency(c echo.Context) error {
	var in struct {
		Ms int64 `json:"ms"`
	}
	if err := c.Bind(&in); err != nil {
		return badRequest(c, "invalid json body")
	}
	if in.Ms < 0 || in.Ms > 30000 {
		return badRequest(c, "ms must be between 0 and 30000")
	}
	h.levers.SetLatencyMs(in.Ms)
	h.logger.Warn("latency lever set", "latency_ms", in.Ms)
	return c.JSON(http.StatusOK, h.levers.currentState())
}

func (h *Handler) errors(c echo.Context) error {
	var in struct {
		Rate float64 `json:"rate"`
	}
	if err := c.Bind(&in); err != nil {
		return badRequest(c, "invalid json body")
	}
	if in.Rate < 0 || in.Rate > 1 {
		return badRequest(c, "rate must be between 0 and 1")
	}
	h.levers.SetErrorRate(in.Rate)
	h.logger.Warn("error lever set", "error_rate", in.Rate)
	return c.JSON(http.StatusOK, h.levers.currentState())
}

func (h *Handler) cpu(c echo.Context) error {
	var in struct {
		Ms int64 `json:"ms"`
	}
	if err := c.Bind(&in); err != nil {
		return badRequest(c, "invalid json body")
	}
	if in.Ms < 0 || in.Ms > 1000 {
		return badRequest(c, "ms must be between 0 and 1000")
	}
	h.levers.SetCPUMs(in.Ms)
	h.logger.Warn("cpu lever set", "cpu_ms", in.Ms)
	return c.JSON(http.StatusOK, h.levers.currentState())
}

func (h *Handler) reset(c echo.Context) error {
	h.levers.SetLatencyMs(0)
	h.levers.SetErrorRate(0)
	h.levers.SetCPUMs(0)
	h.logger.Warn("demo levers reset")
	return c.JSON(http.StatusOK, h.levers.currentState())
}

func badRequest(c echo.Context, msg string) error {
	return c.JSON(http.StatusBadRequest, map[string]string{"error": msg})
}
