// Package semaphore — минимальный клиент Semaphore REST API (ADR-0014 §2): контроллер сам не
// выполняет Ansible, а инициирует job в Semaphore, передавая туда spec модуля как extra vars
// (docs/adr/0014-platform-controller-architecture.md §1).
package semaphore

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client — HTTP-клиент Semaphore API, аутентификация через персональный API-токен
// (Authorization: Bearer, semaphoreui.com/docs/administration-guide/api/), не сессионную куку —
// токен не истекает при рестарте контроллера.
type Client struct {
	baseURL    string
	hostHeader string
	token      string
	projectID  int
	http       *http.Client
}

// Options — опции пилотного стенда platform/cicd (ADR-0014 §2, Фаза 3): у Semaphore нет
// публичного DNS/валидного TLS — маршрутизация по Host-заголовку через встроенный k3s Traefik
// (тот же приём, что curl -H "Host: ..." в platform/cicd/README.md), сертификат самоподписанный.
// Оба поля — временное решение для одноузлового пилота, не для боевого стенда с публичным TLS.
type Options struct {
	// HostHeader — значение заголовка Host (IngressRoute роутит по нему, не по IP baseURL).
	HostHeader string
	// InsecureSkipTLSVerify — самоподписанный сертификат встроенного k3s Traefik.
	InsecureSkipTLSVerify bool
}

func NewClient(baseURL, token string, projectID int, opts Options) *Client {
	transport := &http.Transport{}
	if opts.InsecureSkipTLSVerify {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // пилот, самоподписанный сертификат
	}
	return &Client{
		baseURL:    baseURL,
		hostHeader: opts.HostHeader,
		token:      token,
		projectID:  projectID,
		http:       &http.Client{Timeout: 30 * time.Second, Transport: transport},
	}
}

func (c *Client) setHost(req *http.Request) {
	if c.hostHeader != "" {
		req.Host = c.hostHeader
	}
}

// StartTaskRequest — тело POST /api/project/{project_id}/tasks. environment — JSON-строка с
// extra vars, переопределяющая Environment, привязанный к Task Template (Module.spec.vars).
type startTaskRequest struct {
	TemplateID  int    `json:"template_id"`
	Environment string `json:"environment,omitempty"`
}

// Task — подмножество полей ответа Semaphore, нужное контроллеру для status Module.
type Task struct {
	ID     int    `json:"id"`
	Status string `json:"status"`
}

// StartTask запускает Task Template templateID с переданными extra vars и возвращает
// созданный Task (в первую очередь — его ID, для Module.status.semaphoreJobID).
func (c *Client) StartTask(templateID int, vars map[string]interface{}) (*Task, error) {
	var envJSON string
	if len(vars) > 0 {
		b, err := json.Marshal(vars)
		if err != nil {
			return nil, fmt.Errorf("marshal vars: %w", err)
		}
		envJSON = string(b)
	}

	reqBody, err := json.Marshal(startTaskRequest{TemplateID: templateID, Environment: envJSON})
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	url := fmt.Sprintf("%s/api/project/%d/tasks", c.baseURL, c.projectID)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.token)
	c.setHost(req)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("semaphore API returned %d: %s", resp.StatusCode, string(body))
	}

	var task Task
	if err := json.Unmarshal(body, &task); err != nil {
		return nil, fmt.Errorf("unmarshal response %q: %w", string(body), err)
	}
	return &task, nil
}

// GetTask — GET /api/project/{project_id}/tasks/{task_id}, используется, чтобы после запуска
// прочитать актуальный status задачи (для status.conditions Module) — сам StartTask отдаёт
// только начальный статус на момент создания.
func (c *Client) GetTask(taskID int) (*Task, error) {
	url := fmt.Sprintf("%s/api/project/%d/tasks/%d", c.baseURL, c.projectID, taskID)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	c.setHost(req)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("semaphore API returned %d: %s", resp.StatusCode, string(body))
	}

	var task Task
	if err := json.Unmarshal(body, &task); err != nil {
		return nil, fmt.Errorf("unmarshal response %q: %w", string(body), err)
	}
	return &task, nil
}
