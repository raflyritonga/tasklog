package obs

import (
	"time"

	"github.com/labstack/echo/v4"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

func Metrics() echo.MiddlewareFunc {
	meter := otel.Meter("tasklog-api")
	counter, _ := meter.Int64Counter("http.server.request.count")
	duration, _ := meter.Float64Histogram(
		"http.server.request.duration",
		metric.WithUnit("s"),
		metric.WithExplicitBucketBoundaries(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
	)
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()
			err := next(c)
			attrs := metric.WithAttributes(
				attribute.String("route", c.Path()),
				attribute.String("method", c.Request().Method),
				attribute.Int("status", c.Response().Status),
			)
			ctx := c.Request().Context()
			counter.Add(ctx, 1, attrs)
			duration.Record(ctx, time.Since(start).Seconds(), attrs)
			return err
		}
	}
}
