// Package controller — контроллер Module (ADR-0014 §2/§3, ROADMAP.md пункт 7): событийный
// reconcile (create/update spec) → вызов Semaphore API → короткий poll-loop до завершения
// job'а → запись итогового status, и далее непрерывный drift-loop (Фаза 4) — переприменение
// того же generation с интервалом driftInterval, даже если spec не менялся, чтобы обнаруживать
// дрейф реальной инфраструктуры от декларации. GenerationChangedPredicate в main.go фильтрует
// только watch-события (не реагирует на собственные же записи status, не меняющие
// metadata.generation) — периодический RequeueAfter ниже работает независимо от предиката.
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

// driftInterval — как часто переприменять уже устаканившийся (terminal Ready) модуль заново,
// на случай дрейфа реальной инфраструктуры от декларации (ADR-0014 §3). Безопасно именно потому,
// что идемпотентность ролей коллекции — жёсткое требование (CLAUDE.md, `idempotence: changed=0`
// в каждом molecule-сценарии), не допущение, принятое специально для этого контроллера. Пилотное
// значение, маленькое ради демонстрации в разумное время — тот же нерешённый вопрос ADR-0014
// «период requeue-цикла», что и pollInterval выше.
const driftInterval = 30 * time.Second

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

	if hasJobID && lastAppliedRevision == generation {
		readyStatus, hasReady := readyConditionStatus(obj)
		if hasReady && readyStatus == "Unknown" {
			// Job для текущего generation ещё выполняется (предыдущая итерация poll-requeue) —
			// не стартуем новый, а опрашиваем существующий.
			return r.pollTask(ctx, obj, int(existingJobID))
		}

		// Job для текущего generation уже устаканился (Ready True/False) — не спешим стартовать
		// новый сразу, а ждём driftInterval с последней синхронизации (Фаза 4).
		if hasReady {
			lastSyncTime, _, _ := unstructured.NestedString(obj.Object, "status", "lastSyncTime")
			if since, ok := timeSince(lastSyncTime); ok && since < driftInterval {
				return ctrl.Result{RequeueAfter: driftInterval - since}, nil
			}
			logger.Info("drift-check: переприменяю устаканившийся Module заново", "module", req.NamespacedName)
		}
		// иначе (нет ни Unknown, ни распознанного terminal-condition) — падаем через на общий
		// путь запуска нового job'а, как и для первого reconcile этого generation.
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
	// RequeueAfter: driftInterval (не ctrl.Result{}) — иначе Reconcile для этого Module больше
	// никогда не вызовется без нового watch-события (create/update spec), и drift-check (Фаза 4)
	// не с чего будет стартовать. Проверка "elapsed < driftInterval" наверху Reconcile корректно
	// обработает и этот таймер, и любой более ранний внеплановый вызов.
	if task.Status == "success" {
		return ctrl.Result{RequeueAfter: driftInterval}, r.setSucceededCondition(ctx, obj, taskID, task.Status)
	}
	return ctrl.Result{RequeueAfter: driftInterval}, r.setFailedCondition(ctx, obj, "SemaphoreTaskFailed",
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

// readyConditionStatus достаёт status.conditions[type=Ready].status из уже прочитанного
// объекта — используется, чтобы отличить «job ещё выполняется» (Unknown, продолжать poll)
// от «устаканилось» (True/False, пора запускать drift-check по таймеру).
func readyConditionStatus(obj *unstructured.Unstructured) (string, bool) {
	conditions, found, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if !found {
		return "", false
	}
	for _, c := range conditions {
		cond, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if cond["type"] != "Ready" {
			continue
		}
		status, _ := cond["status"].(string)
		return status, status != ""
	}
	return "", false
}

// timeSince парсит RFC3339-таймстамп из status и возвращает, сколько времени прошло с тех пор.
func timeSince(rfc3339 string) (time.Duration, bool) {
	if rfc3339 == "" {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339, rfc3339)
	if err != nil {
		return 0, false
	}
	return time.Since(t), true
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
