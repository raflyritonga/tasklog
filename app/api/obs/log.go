package obs

import (
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"go.opentelemetry.io/otel/trace"
)

func NewLogger(service string) *slog.Logger {
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if a.Key == slog.TimeKey {
				a.Key = "ts"
			}
			return a
		},
	})
	return slog.New(handler).With("service", service)
}

func RequestLogger(logger *slog.Logger) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()
			err := next(c)
			if err != nil {
				c.Error(err)
			}
			req := c.Request()
			spanContext := trace.SpanContextFromContext(req.Context())
			traceID := ""
			spanID := ""
			if spanContext.HasTraceID() {
				traceID = spanContext.TraceID().String()
			}
			if spanContext.HasSpanID() {
				spanID = spanContext.SpanID().String()
			}
			status := c.Response().Status
			attrs := []any{
				"route", c.Path(),
				"status", status,
				"duration_ms", float64(time.Since(start).Microseconds()) / 1000,
				"trace_id", traceID,
				"span_id", spanID,
				"client_ip", c.RealIP(),
				slog.Group("dd", "trace_id", datadogID(traceID), "span_id", datadogID(spanID)),
			}
			if err != nil {
				attrs = append(attrs, "err", err.Error())
			}
			msg := req.Method + " " + req.URL.Path
			if status >= 500 {
				logger.ErrorContext(req.Context(), msg, attrs...)
			} else {
				logger.InfoContext(req.Context(), msg, attrs...)
			}
			return nil
		}
	}
}

func datadogID(id string) string {
	if len(id) < 16 {
		return ""
	}
	value, err := strconv.ParseUint(id[len(id)-16:], 16, 64)
	if err != nil {
		return ""
	}
	return strconv.FormatUint(value, 10)
}
