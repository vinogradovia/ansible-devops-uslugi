// Package controller — MVP-контроллер Module (ADR-0014 §2/§3, Фаза 3, ROADMAP.md пункт 7):
// событийный reconcile (create/update spec) → вызов Semaphore API → запись status. Ещё БЕЗ
// непрерывного drift-loop (Фаза 4) — GenerationChangedPredicate в main.go гарантирует, что
// Reconcile не вызывается на собственные же изменения status (не меняют metadata.generation).
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

// ModuleReconciler — reconcile-логика для Module CR. Semaphore — единственный исполнительный
// backend (ADR-0014 §2): контроллер не вызывает ansible-playbook/ansible-runner сам.
type ModuleReconciler struct {
	client.Client
	Semaphore *semaphore.Client
}

func (r *ModuleReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(ModuleGVK)
	if err := r.Get(ctx, req.NamespacedName, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get module: %w", err)
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
	logger.Info("Semaphore task запущен, пишу status", "taskID", task.ID, "taskStatus", task.Status)

	err = r.setSucceededCondition(ctx, obj, task.ID, task.Status)
	if err != nil {
		logger.Error(err, "не удалось записать status Module")
	} else {
		logger.Info("status Module записан")
	}
	return ctrl.Result{}, err
}

// setSucceededCondition записывает status после успешного запуска Semaphore task.
// "Успешно" здесь значит «job поставлен в очередь» — не «job завершился OK» (Semaphore
// выполняет job асинхронно, отслеживание итогового результата — Не проработано, см. README).
func (r *ModuleReconciler) setSucceededCondition(ctx context.Context, obj *unstructured.Unstructured, taskID int, taskStatus string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "True",
			"reason":             "SemaphoreTaskStarted",
			"message":            fmt.Sprintf("Semaphore task %d поставлен в очередь (status=%s)", taskID, taskStatus),
			"lastTransitionTime": now,
		},
	}
	return r.patchStatus(ctx, obj, map[string]interface{}{
		"conditions":          conditions,
		"lastAppliedRevision": fmt.Sprintf("%d", obj.GetGeneration()),
		"lastSyncTime":        now,
		"semaphoreJobID":      int64(taskID),
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
