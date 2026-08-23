package task

import (
	"context"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

type Handler struct {
	store *Store
}

func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

func (h *Handler) Register(g *echo.Group) {
	g.GET("/tasks", h.list)
	g.POST("/tasks", h.create)
	g.GET("/tasks/:id", h.get)
	g.PUT("/tasks/:id", h.update)
	g.DELETE("/tasks/:id", h.delete)
}

func (h *Handler) list(c echo.Context) error {
	ctx := c.Request().Context()
	tasks, err := h.store.List(ctx)
	if err != nil {
		return err
	}
	tag(ctx, attribute.String("task.operation", "list"), attribute.Int("task.count", len(tasks)))
	return c.JSON(http.StatusOK, tasks)
}

func tag(ctx context.Context, attrs ...attribute.KeyValue) {
	trace.SpanFromContext(ctx).SetAttributes(attrs...)
}

func (h *Handler) get(c echo.Context) error {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		return notFound(c)
	}
	t, err := h.store.Get(c.Request().Context(), id.String())
	if errors.Is(err, ErrNotFound) {
		return notFound(c)
	}
	if err != nil {
		return err
	}
	return c.JSON(http.StatusOK, t)
}

func (h *Handler) create(c echo.Context) error {
	var in Input
	if err := c.Bind(&in); err != nil {
		return badRequest(c, "invalid json body")
	}
	if msg := in.Validate(); msg != "" {
		return badRequest(c, msg)
	}
	ctx := c.Request().Context()
	t, err := h.store.Create(ctx, in)
	if err != nil {
		return err
	}
	tag(ctx, attribute.String("task.operation", "create"), attribute.String("task.status", t.Status))
	return c.JSON(http.StatusCreated, t)
}

func (h *Handler) update(c echo.Context) error {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		return notFound(c)
	}
	var in Input
	if err := c.Bind(&in); err != nil {
		return badRequest(c, "invalid json body")
	}
	if msg := in.Validate(); msg != "" {
		return badRequest(c, msg)
	}
	ctx := c.Request().Context()
	t, err := h.store.Update(ctx, id.String(), in)
	if errors.Is(err, ErrNotFound) {
		return notFound(c)
	}
	if err != nil {
		return err
	}
	tag(ctx, attribute.String("task.operation", "update"), attribute.String("task.status", t.Status))
	return c.JSON(http.StatusOK, t)
}

func (h *Handler) delete(c echo.Context) error {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		return notFound(c)
	}
	err = h.store.Delete(c.Request().Context(), id.String())
	if errors.Is(err, ErrNotFound) {
		return notFound(c)
	}
	if err != nil {
		return err
	}
	return c.NoContent(http.StatusNoContent)
}

func notFound(c echo.Context) error {
	return c.JSON(http.StatusNotFound, map[string]string{"error": "task not found"})
}

func badRequest(c echo.Context, msg string) error {
	return c.JSON(http.StatusBadRequest, map[string]string{"error": msg})
}
