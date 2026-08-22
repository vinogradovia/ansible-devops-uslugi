// Package controller — MVP-контроллер Module (ADR-0014 §2/§3, Фаза 3, ROADMAP.md пункт 7):
// событийный reconcile (create/update spec) → вызов Semaphore API → запись status, плюс
// короткий poll-loop до завершения job'а (Фаза 3, продолжение — README.md). Ещё БЕЗ
// непрерывного drift-loop поверх уже завершённых job'ов (Фаза 4) — GenerationChangedPredicate в
// main.go гарантирует, что Reconcile не вызывается на собственные же изменения status (не меняют
// metadata.generation); poll-requeue ниже — временный RequeueAfter только пока job не завершился.
package controller

import (
	"context"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/vinogradovia/ansible-devops-uslugi/platform-controller/internal/semaphore"
)

var ModuleGVK = schema.GroupVersionKind{
	Group:   "platform.devops.uslugi",
	Version: "v1alpha1",
	Kind:    "Module",
}

// pollInterval — как часто опрашивать Semaphore, пока job не завершился. Пилотное значение,
// не вынесено в конфигурацию — для одного/нескольких модулей на демо-стенде нагрузка на
// Semaphore API пренебрежимо мала (ROADMAP.md, Фаза 4, «период requeue-цикла» — тот же
// нерешённый вопрос ADR-0014, актуальный уже здесь, ещё до самого drift-loop).
const pollInterval = 5 * time.Second

// terminalTaskStatuses — статусы Semaphore task, после которых job больше не изменится
// (semaphoreui.com API): дальше опрашивать нет смысла.
var terminalTaskStatuses = map[string]bool{
	"success": true,
	"error":   true,
	"stopped": true,
}

// ModuleReconciler — reconcile-логика для Module CR. Semaphore — единственный исполнительный
// backend (ADR-0014 §2): контроллер не вызывает ansible-playbook/ansible-runner сам.
type ModuleReconciler struct {
	client.Client
	// APIReader — некэширующее чтение (mgr.GetAPIReader()), напрямую с API-сервера. Найдено
	// реальным прогоном: обычный (кэшированный) r.Get() иногда возвращает Module без только
	// что записанного этим же контроллером status (informer-кэш не успевает увидеть свою же
	// запись за pollInterval) — Reconcile ошибочно решает, что job ещё не запущен, и стартует
	// второй Semaphore task для того же generation. Для решения «запущен ли уже job» критично
	// читать актуальный status, поэтому именно здесь — APIReader, а не кэш.
	APIReader client.Reader
	Semaphore *semaphore.Client
}

func (r *ModuleReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(ModuleGVK)
	if err := r.APIReader.Get(ctx, req.NamespacedName, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get module: %w", err)
	}

	generation := fmt.Sprintf("%d", obj.GetGeneration())
	lastAppliedRevision, _, _ := unstructured.NestedString(obj.Object, "status", "lastAppliedRevision")
	existingJobID, hasJobID, _ := unstructured.NestedInt64(obj.Object, "status", "semaphoreJobID")

	// Job для текущего spec (generation) уже запущен раньше этим же контроллером (в т.ч. на
	// предыдущей итерации poll-requeue ниже) — не стартуем новый, а опрашиваем существующий.
	if hasJobID && lastAppliedRevision == generation {
		return r.pollTask(ctx, obj, int(existingJobID))
	}

	templateID, found, err := unstructured.NestedInt64(obj.Object, "spec", "semaphoreTemplateID")
	if err != nil || !found {
		return ctrl.Result{}, r.setFailedCondition(ctx, obj, "MissingSemaphoreTemplateID",
			"spec.semaphoreTemplateID не задан или имеет неверный тип")
	}

	vars, _, err := unstructured.NestedMap(obj.Object, "spec", "vars")
	if err != nil {
		return ctrl.Result{}, r.setFailedCondition(ctx, obj, "InvalidSpecVars", err.Error())
	}

	logger.Info("запускаю Semaphore Task Template", "templateID", templateID, "module", req.NamespacedName)
	task, err := r.Semaphore.StartTask(int(templateID), vars)
	if err != nil {
		logger.Error(err, "не удалось запустить Semaphore task")
		return ctrl.Result{}, r.setFailedCondition(ctx, obj, "SemaphoreStartTaskFailed", err.Error())
	}
	logger.Info("Semaphore task запущен, буду опрашивать до завершения", "taskID", task.ID, "taskStatus", task.Status)

	if err := r.setProgressingCondition(ctx, obj, task.ID, task.Status, generation); err != nil {
		return ctrl.Result{}, fmt.Errorf("write progressing status: %w", err)
	}
	return ctrl.Result{RequeueAfter: pollInterval}, nil
}

// pollTask опрашивает уже запущенный Semaphore task. Пока не в терминальном статусе —
// перезапрашивает через pollInterval, ничего не переписывая (Progressing уже выставлен). При
// сетевой ошибке опроса — не трогает status, а возвращает err (стандартный
// exponential-backoff requeue controller-runtime): временная недоступность Semaphore не должна
// сразу переводить Module в Ready=False.
func (r *ModuleReconciler) pollTask(ctx context.Context, obj *unstructured.Unstructured, taskID int) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	task, err := r.Semaphore.GetTask(taskID)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("get semaphore task %d: %w", taskID, err)
	}

	if !terminalTaskStatuses[task.Status] {
		logger.Info("Semaphore task ещё выполняется", "taskID", taskID, "taskStatus", task.Status)
		return ctrl.Result{RequeueAfter: pollInterval}, nil
	}

	logger.Info("Semaphore task завершился", "taskID", taskID, "taskStatus", task.Status)
	if task.Status == "success" {
		return ctrl.Result{}, r.setSucceededCondition(ctx, obj, taskID, task.Status)
	}
	return ctrl.Result{}, r.setFailedCondition(ctx, obj, "SemaphoreTaskFailed",
		fmt.Sprintf("Semaphore task %d завершился со статусом %q", taskID, task.Status))
}

// setProgressingCondition — job поставлен в очередь/выполняется, итог ещё не известен.
func (r *ModuleReconciler) setProgressingCondition(ctx context.Context, obj *unstructured.Unstructured, taskID int, taskStatus, generation string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "Unknown",
			"reason":             "SemaphoreTaskRunning",
			"message":            fmt.Sprintf("Semaphore task %d выполняется (status=%s)", taskID, taskStatus),
			"lastTransitionTime": now,
		},
	}
	return r.patchStatus(ctx, obj, map[string]interface{}{
		"conditions":          conditions,
		"lastAppliedRevision": generation,
		"lastSyncTime":        now,
		"semaphoreJobID":      int64(taskID),
	})
}

// setSucceededCondition — job реально завершился успехом (не «поставлен в очередь», как было
// до появления pollTask/GetTask).
func (r *ModuleReconciler) setSucceededCondition(ctx context.Context, obj *unstructured.Unstructured, taskID int, taskStatus string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "True",
			"reason":             "SemaphoreTaskSucceeded",
			"message":            fmt.Sprintf("Semaphore task %d завершился успешно (status=%s)", taskID, taskStatus),
			"lastTransitionTime": now,
		},
	}
	return r.patchStatus(ctx, obj, map[string]interface{}{
		"conditions":   conditions,
		"lastSyncTime": now,
	})
}

func (r *ModuleReconciler) setFailedCondition(ctx context.Context, obj *unstructured.Unstructured, reason, message string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "False",
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": now,
		},
	}
	return r.patchStatus(ctx, obj, map[string]interface{}{
		"conditions":   conditions,
		"lastSyncTime": now,
	})
}

func (r *ModuleReconciler) patchStatus(ctx context.Context, obj *unstructured.Unstructured, status map[string]interface{}) error {
	for k, v := range status {
		if err := unstructured.SetNestedField(obj.Object, v, "status", k); err != nil {
			return fmt.Errorf("set status.%s: %w", k, err)
		}
	}
	if err := r.Status().Update(ctx, obj); err != nil {
		return fmt.Errorf("update status: %w", err)
	}
	return nil
}
