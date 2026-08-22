// platform-controller — MVP (ADR-0014 §2/§3, Фаза 3). Запуск локально против кластера,
// заданного KUBECONFIG (не in-cluster) — Фаза 3 сознательно не включает деплой самого
// контроллера в кластер, только доказательство reconcile-логики (README.md, «Не проработано»).
package main

import (
	"os"
	"strconv"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	"github.com/vinogradovia/ansible-devops-uslugi/platform-controller/internal/controller"
	"github.com/vinogradovia/ansible-devops-uslugi/platform-controller/internal/semaphore"
)

func mustEnv(name string) string {
	v := os.Getenv(name)
	if v == "" {
		ctrl.Log.Error(nil, "обязательная переменная окружения не задана", "name", name)
		os.Exit(1)
	}
	return v
}

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))

	semaphoreURL := mustEnv("SEMAPHORE_URL")
	semaphoreToken := mustEnv("SEMAPHORE_TOKEN")
	projectIDStr := mustEnv("SEMAPHORE_PROJECT_ID")
	projectID, err := strconv.Atoi(projectIDStr)
	if err != nil {
		ctrl.Log.Error(err, "SEMAPHORE_PROJECT_ID должен быть числом")
		os.Exit(1)
	}

	semClient := semaphore.NewClient(semaphoreURL, semaphoreToken, projectID, semaphore.Options{
		HostHeader:            os.Getenv("SEMAPHORE_HOST_HEADER"),
		InsecureSkipTLSVerify: os.Getenv("SEMAPHORE_INSECURE_TLS") == "true",
	})

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		ctrl.Log.Error(err, "не удалось зарегистрировать core-схему")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
	})
	if err != nil {
		ctrl.Log.Error(err, "не удалось создать manager")
		os.Exit(1)
	}

	moduleTarget := &unstructured.Unstructured{}
	moduleTarget.SetGroupVersionKind(controller.ModuleGVK)

	reconciler := &controller.ModuleReconciler{
		Client:    mgr.GetClient(),
		APIReader: mgr.GetAPIReader(),
		Semaphore: semClient,
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(moduleTarget).
		WithEventFilter(predicate.GenerationChangedPredicate{}).
		Complete(reconciler); err != nil {
		ctrl.Log.Error(err, "не удалось зарегистрировать контроллер")
		os.Exit(1)
	}

	ctrl.Log.Info("platform-controller запущен, слежу за Module CR")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "manager завершился с ошибкой")
		os.Exit(1)
	}
}
