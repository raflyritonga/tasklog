package report

import (
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/labstack/echo/v4"
)

type Handler struct {
	db *pgxpool.Pool
}

func NewHandler(db *pgxpool.Pool) *Handler {
	return &Handler{db: db}
}

func (h *Handler) Register(g *echo.Group) {
	g.GET("/reports/summary", h.summary)
}

type summary struct {
	Total int64 `json:"total"`
	Todo  int64 `json:"todo"`
	Doing int64 `json:"doing"`
	Done  int64 `json:"done"`
}

const summaryQuery = "select (select count(*) from tasks) as total, (select count(*) from tasks where status = 'todo') as todo, (select count(*) from tasks where status = 'doing') as doing, (select count(*) from tasks where status = 'done') as done from pg_sleep(0.3)"

func (h *Handler) summary(c echo.Context) error {
	var s summary
	row := h.db.QueryRow(c.Request().Context(), summaryQuery)
	if err := row.Scan(&s.Total, &s.Todo, &s.Doing, &s.Done); err != nil {
		return err
	}
	return c.JSON(http.StatusOK, s)
}
