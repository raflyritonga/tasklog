package task

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

var ErrNotFound = errors.New("task not found")

const cacheTTL = 30 * time.Second

const taskColumns = "id, title, status, created_at, updated_at"

type Store struct {
	db  *pgxpool.Pool
	rdb *redis.Client
}

func NewStore(db *pgxpool.Pool, rdb *redis.Client) *Store {
	return &Store{db: db, rdb: rdb}
}

func (s *Store) List(ctx context.Context) ([]Task, error) {
	var tasks []Task
	if s.cacheGet(ctx, "tasks:all", &tasks) {
		return tasks, nil
	}
	rows, err := s.db.Query(ctx, "select "+taskColumns+" from tasks order by created_at desc limit 100")
	if err != nil {
		return nil, err
	}
	tasks, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Task])
	if err != nil {
		return nil, err
	}
	if tasks == nil {
		tasks = []Task{}
	}
	s.cacheSet(ctx, "tasks:all", tasks)
	return tasks, nil
}

func (s *Store) Get(ctx context.Context, id string) (Task, error) {
	var t Task
	if s.cacheGet(ctx, "tasks:"+id, &t) {
		return t, nil
	}
	row := s.db.QueryRow(ctx, "select "+taskColumns+" from tasks where id = $1", id)
	if err := row.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Task{}, ErrNotFound
		}
		return Task{}, err
	}
	s.cacheSet(ctx, "tasks:"+id, t)
	return t, nil
}

func (s *Store) Create(ctx context.Context, in Input) (Task, error) {
	var t Task
	row := s.db.QueryRow(ctx, "insert into tasks (title, status) values ($1, $2) returning "+taskColumns, in.Title, in.Status)
	if err := row.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return Task{}, err
	}
	s.invalidate(ctx, t.ID)
	return t, nil
}

func (s *Store) Update(ctx context.Context, id string, in Input) (Task, error) {
	var t Task
	row := s.db.QueryRow(ctx, "update tasks set title = $1, status = $2, updated_at = now() where id = $3 returning "+taskColumns, in.Title, in.Status, id)
	if err := row.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Task{}, ErrNotFound
		}
		return Task{}, err
	}
	s.invalidate(ctx, id)
	return t, nil
}

func (s *Store) Delete(ctx context.Context, id string) error {
	tag, err := s.db.Exec(ctx, "delete from tasks where id = $1", id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	s.invalidate(ctx, id)
	return nil
}

func (s *Store) invalidate(ctx context.Context, id string) {
	s.rdb.Del(ctx, "tasks:all", "tasks:"+id)
}

func (s *Store) cacheGet(ctx context.Context, key string, dest any) bool {
	data, err := s.rdb.Get(ctx, key).Bytes()
	if err != nil {
		return false
	}
	return json.Unmarshal(data, dest) == nil
}

func (s *Store) cacheSet(ctx context.Context, key string, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		return
	}
	s.rdb.Set(ctx, key, data, cacheTTL)
}
