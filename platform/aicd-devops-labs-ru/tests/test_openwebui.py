"""ADR-0022 §14 — живые инфраструктурные тесты уже развёрнутого Open WebUI (ROADMAP.md №65).

Первый testinfra-style pytest в коллекции (в отличие от Molecule, который тестирует роль
изолированно pre-deploy, этот модуль проверяет реально задеплоенное окружение
aicd-devops-labs-ru после прогона site.yml — re-runnable регрессионный чек, не одноразовая
ручная проверка).

Запуск: poetry run pytest platform/aicd-devops-labs-ru/tests/test_openwebui.py -v
Требует уже существующие на диске артефакты прогона site.yml: kubeconfig и внутренний PKI CA
(оба фетчатся ansible.builtin.fetch в play "Platform CI/CD infra", см. site.yml).
"""

from pathlib import Path

import pytest
from kubernetes import client, config
from kubernetes.stream import stream

ANSIBLE_DIR = Path(__file__).resolve().parent.parent / "ansible"
KUBECONFIG_PATH = ANSIBLE_DIR / ".kube-tmp" / "aicd-labs" / "etc" / "rancher" / "k3s" / "k3s.yaml"

NAMESPACE = "platform"
DEPLOYMENT_NAME = "openwebui-openwebui"
PVC_NAME = "openwebui-data"
DOMAIN = "openwebui.aicd.devops-labs.ru"
SSO_DOMAIN = "sso.aicd.devops-labs.ru"


@pytest.fixture(scope="module")
def k8s_apps_v1():
    config.load_kube_config(config_file=str(KUBECONFIG_PATH))
    return client.AppsV1Api()


@pytest.fixture(scope="module")
def k8s_core_v1():
    config.load_kube_config(config_file=str(KUBECONFIG_PATH))
    return client.CoreV1Api()


def test_deployment_ready(k8s_apps_v1):
    deploy = k8s_apps_v1.read_namespaced_deployment(DEPLOYMENT_NAME, NAMESPACE)
    assert (deploy.status.ready_replicas or 0) >= 1
    assert deploy.status.replicas == deploy.status.ready_replicas


def test_pvc_bound(k8s_core_v1):
    pvc = k8s_core_v1.read_namespaced_persistent_volume_claim(PVC_NAME, NAMESPACE)
    assert pvc.status.phase == "Bound"


def test_tls_secret_present(k8s_core_v1):
    """Проект не использует cert-manager — TLS выпускается напрямую из OpenBao PKI обычным
    k8s Secret (tasks/issue-tls-cert.yml), без CRD Certificate."""
    secret = k8s_core_v1.read_namespaced_secret("openwebui-tls", NAMESPACE)
    assert secret.type == "kubernetes.io/tls"
    assert "tls.crt" in secret.data and "tls.key" in secret.data


def test_pod_env_mounted_no_secret_leak(k8s_core_v1):
    """OAUTH_*/WEBUI_SECRET_KEY реально смонтированы через secretKeyRef, не голым значением."""
    pods = k8s_core_v1.list_namespaced_pod(
        NAMESPACE, label_selector="app.kubernetes.io/instance=openwebui"
    )
    assert len(pods.items) >= 1
    container = pods.items[0].spec.containers[0]
    env_by_name = {e.name: e for e in container.env}
    for secret_env in ("OAUTH_CLIENT_SECRET", "WEBUI_SECRET_KEY", "OPENAI_API_KEY"):
        assert secret_env in env_by_name
        assert env_by_name[secret_env].value_from is not None
        assert env_by_name[secret_env].value_from.secret_key_ref.name == "openwebui-secrets"


def test_unauthenticated_redirects_to_sso(k8s_core_v1):
    """Проверка изнутри кластера (curl --resolve на ClusterIP Traefik) — control-хост, с
    которого может запускаться этот файл, не обязан иметь /etc/hosts-запись или маршрут до
    10.10.10.0/24 (README документирует это как требование для ОПЕРАТОРА, не для CI/тестового
    окружения); тот же прием, что уже применялся весь этот сеанс для живых проверок."""
    pods = k8s_core_v1.list_namespaced_pod(
        NAMESPACE, label_selector="app.kubernetes.io/instance=openwebui"
    )
    assert len(pods.items) >= 1
    traefik_svc = k8s_core_v1.read_namespaced_service("traefik", "kube-system")
    traefik_ip = traefik_svc.spec.cluster_ip
    resp = stream(
        k8s_core_v1.connect_get_namespaced_pod_exec,
        pods.items[0].metadata.name,
        NAMESPACE,
        command=[
            "curl", "-sS", "-L", "-o", "/dev/null", "-w", "%{url_effective}",
            "--cacert", "/etc/ssl/certs/aicd-platform-ca.pem",
            "--resolve", f"{DOMAIN}:443:{traefik_ip}",
            "--resolve", f"{SSO_DOMAIN}:443:{traefik_ip}",
            f"https://{DOMAIN}/",
        ],
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )
    assert SSO_DOMAIN in resp


def test_infra_panel_lists_openwebui(k8s_core_v1):
    """/assets/config.yml — напрямую в поде (не через forwardAuth-домен, тот же приём, что уже
    применялся для проверки пункта LiteLLM, ROADMAP.md №59)."""
    pods = k8s_core_v1.list_namespaced_pod(
        NAMESPACE, label_selector="app.kubernetes.io/instance=infra-panel"
    )
    assert len(pods.items) >= 1
    resp = stream(
        k8s_core_v1.connect_get_namespaced_pod_exec,
        pods.items[0].metadata.name,
        NAMESPACE,
        command=["wget", "-qO-", "http://localhost:8080/assets/config.yml"],
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )
    assert "Open WebUI" in resp
