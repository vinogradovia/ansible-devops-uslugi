#!/usr/bin/env bash
# ADR-0006: единая обёртка над Terraform+libvirt / ansible-playbook для запуска и сноса
# демо-стендов из demo/<case>/{terraform,ansible}. Все кейсы (mysql-ha-platform,
# postgresql-ha-platform, monitoring-k3s-platform, ...) имеют одинаковую структуру каталогов —
# скрипт не хардкодит имена кейсов, только читает опциональные per-case файлы:
#   ansible-extra-args — доп. флаги ansible-playbook (нужен monitoring-k3s-platform:
#                         xanmanning.k3s — never-тег зависимость, требует явный --tags all,init)
#   infra-panel-url     — ссылка на infra_panel (ADR-0008), печатается после успешного up
#                         (заведён только у mysql-ha-platform — единственного кейса с этой ролью)
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") up <case-name>
       $(basename "$0") down <case-name>

up   — tofu apply, ожидание SSH на всех VM, затем ansible-playbook site.yml.
down — tofu destroy (безвозвратно уничтожает VM стенда).

Доступные стенды (demo/*/terraform):
$(find "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" -maxdepth 2 -mindepth 2 -type d -name terraform -printf '  %h\n' 2>/dev/null | xargs -n1 basename | sed 's/^/  /')

Переменные окружения:
  TOFU                          — путь к бинарю OpenTofu (по умолчанию: tofu из PATH)
  TF_VAR_ssh_public_key_path    — override дефолтного SSH-ключа из variables.tf, если он не
                                   совпадает с ключом текущей машины (см. README/ADR-0006 §9);
                                   НЕ редактируйте закоммиченный дефолт под свою машину.
EOF
}

cmd="${1:-}"
case_name="${2:-}"

if [[ -z "$cmd" || -z "$case_name" ]]; then
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case_dir="$repo_root/demo/$case_name"
tf_dir="$case_dir/terraform"
ansible_dir="$case_dir/ansible"

if [[ ! -d "$tf_dir" ]]; then
  echo "Неизвестный стенд: '$case_name' (нет $tf_dir)" >&2
  usage >&2
  exit 1
fi

tofu_bin="${TOFU:-tofu}"

case "$cmd" in
  up)
    ( cd "$tf_dir" && "$tofu_bin" init -input=false && "$tofu_bin" apply -input=false -auto-approve )

    echo "==> Ожидаю SSH на всех VM стенда '$case_name'..."
    ansible_user=$("$tofu_bin" -chdir="$tf_dir" output -json 2>/dev/null | jq -r '.ansible_user.value // "ansible"')
    while read -r ip; do
      [[ -z "$ip" ]] && continue
      # StrictHostKeyChecking=no (не accept-new) — стенды пересоздаются на тех же IP после
      # down/up, старый host key в known_hosts иначе даёт "REMOTE HOST IDENTIFICATION HAS
      # CHANGED" и вечно висит здесь (найдено реальным прогоном). UserKnownHostsFile=/dev/null,
      # чтобы не копить в ~/.ssh/known_hosts записи для этих эфемерных demo-VM.
      until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
          "${ansible_user}@${ip}" true 2>/dev/null; do
        sleep 5
      done
      echo "    $ip: ok"
    done < <("$tofu_bin" -chdir="$tf_dir" output -json vm_ips | jq -r '.[]')

    extra_args=()
    if [[ -f "$case_dir/ansible-extra-args" ]]; then
      # shellcheck disable=SC2207
      extra_args=($(cat "$case_dir/ansible-extra-args"))
    fi

    echo "==> Запускаю site.yml${extra_args:+ (${extra_args[*]})}"
    ( cd "$ansible_dir" && poetry run ansible-playbook -i inventory.yml site.yml "${extra_args[@]}" )

    if [[ -f "$case_dir/infra-panel-url" ]]; then
      echo "==> infra-panel: $(cat "$case_dir/infra-panel-url")"
    fi
    ;;
  down)
    ( cd "$tf_dir" && "$tofu_bin" destroy -input=false -auto-approve )
    ;;
  *)
    usage
    exit 1
    ;;
esac
