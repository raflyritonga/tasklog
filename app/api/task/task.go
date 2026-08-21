package task

import (
	"strings"
	"time"
	"unicode/utf8"
)

type Task struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Input struct {
	Title  string `json:"title"`
	Status string `json:"status"`
}

var validStatuses = map[string]bool{"todo": true, "doing": true, "done": true}

func (in *Input) Validate() string {
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return "title must not be empty"
	}
	if utf8.RuneCountInString(in.Title) > 200 {
		return "title must be at most 200 characters"
	}
	if in.Status == "" {
		in.Status = "todo"
	}
	if !validStatuses[in.Status] {
		return "status must be one of todo, doing, done"
	}
	return ""
}
