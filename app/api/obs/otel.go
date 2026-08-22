package obs

import (
	"context"
	"errors"

	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func Setup(ctx context.Context, endpoint, version string) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName("tasklog-api"),
		semconv.ServiceVersion(version),
		attribute.String("deployment.environment", "poc"),
	)
	tracerOptions := []sdktrace.TracerProviderOption{sdktrace.WithResource(res)}
	if endpoint != "" {
		traceExporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpointURL(endpoint))
		if err != nil {
			return nil, err
		}
		tracerOptions = append(tracerOptions, sdktrace.WithBatcher(traceExporter))
	}
	tracerProvider := sdktrace.NewTracerProvider(tracerOptions...)
	otel.SetTracerProvider(tracerProvider)
	if endpoint == "" {
		return tracerProvider.Shutdown, nil
	}
	metricExporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithEndpointURL(endpoint))
	if err != nil {
		return nil, err
	}
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(meterProvider)
	if err := runtime.Start(); err != nil {
		return nil, err
	}
	return func(shutdownCtx context.Context) error {
		return errors.Join(tracerProvider.Shutdown(shutdownCtx), meterProvider.Shutdown(shutdownCtx))
	}, nil
}
