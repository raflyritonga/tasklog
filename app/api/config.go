package main

import "os"

type config struct {
	port         string
	databaseURL  string
	redisAddr    string
	otlpEndpoint string
}

func loadConfig() config {
	return config{
		port:         envOr("PORT", "8080"),
		databaseURL:  envOr("DATABASE_URL", "postgres://tasklog:tasklog@localhost:5432/tasklog?sslmode=disable"),
		redisAddr:    envOr("REDIS_ADDR", "localhost:6379"),
		otlpEndpoint: os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
