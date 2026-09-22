# Qwen3.8-27B на `aicd-devops-labs-ru` — журнал развёртывания второй локальной модели

- **Статус:** Реализовано и живо проверено (2026-09-22) на `platform/aicd-devops-labs-ru`, нода
  `llm1`. Активная модель — `qwen3_8_27b` (`platform_aicd_devops_labs_ru_llm_active_model`).
- **Дата:** 2026-09-21 — 2026-09-22.

Этот документ — не ADR (архитектурное решение уже зафиксировано в
`docs/adr/0021-agent-platform-model-selection.md`), а журнал одной конкретной сессии
развёртывания: что пробовалось, что не сработало и почему, какая конфигурация в итоге рабочая,
и какие инфраструктурные баги были найдены и исправлены по пути. Держится отдельно от ADR-0021,
потому что ADR-0021 описывает выбор *первой* модели (`Qwen3.6-35B-A3B`) и с тех пор не
переписывался под архитектуру нескольких моделей — см. §«Архитектура: несколько моделей
одновременно» ниже, которая теперь общая для обеих.

## Архитектура: несколько моделей одновременно, каждая — свой Deployment/Service/PVC

До этой сессии в `namespace: llm` был один Deployment `llama-server`, который мутировался при
смене модели (замена образа/аргументов/весов на диске). Пользователь потребовал архитектуру
"новая модель — новый сервис": каждая запись словаря `platform_aicd_devops_labs_ru_llm_models` в
`group_vars/platform_hosts.yml` (`platform/aicd-devops-labs-ru/ansible/`) получает **свой**
Deployment, Service и PersistentVolumeClaim, постоянно существующие независимо от того, какая
модель сейчас активна.

Переключение активной модели — не пересоздание объектов, а изменение
`replicas` через единственную переменную `platform_aicd_devops_labs_ru_llm_active_model`:

```yaml
# роль отыгрывается в site.yml, PLAY "ADR-0021 — локальный инференс"
- name: "LLM: Deployment <модель> (loop по platform_aicd_devops_labs_ru_llm_models)"
  loop: "{{ platform_aicd_devops_labs_ru_llm_models | dict2items }}"
  vars:
    replicas: "{{ 1 if llm_model_item.key == platform_aicd_devops_labs_ru_llm_active_model else 0 }}"
```

Откат на предыдущую модель — не повторное скачивание весов, а просто смена значения
`platform_aicd_devops_labs_ru_llm_active_model` обратно и повторный прогон `site.yml`: старый
Deployment уезжает на `replicas: 0` (GPU освобождается), новый поднимается на `replicas: 1` — веса
уже лежат на его собственном PVC.

Ограничение архитектуры, подтверждённое этой сессией (не решается автоматически): **GPU
физически один**, оба Deployment'а используют один и тот же `nodeSelector: {kubernetes.io/hostname:
llm1}` + `resources.limits.nvidia.com/gpu: 1` — при `replicas: 1` у обеих моделей одновременно
Kubernetes не сможет запланировать оба пода (конфликт за единственный ресурс `nvidia.com/gpu`).
Единовременно активна ровно одна модель — это осознанное ограничение текущего железа, не баг.

На стороне LiteLLM (`helm/values/platform-devops-labs-ru/namespaces/gateway/litellm/values.yaml`)
физическая модель регистрируется под своим полноценным именем (`model_name`), а стабильный
псевдоним для потребителей — `router_settings.model_group_alias`:

```yaml
model_list:
  - model_name: qwen3-8-27b
    litellm_params:
      model: openai/Qwen3.8-27B-UD-IQ3_XXS.gguf
      api_base: http://llama-server-qwen3-8-27b.llm.svc.cluster.local:8080/v1
      api_key: "sk-noauth"
  - model_name: qwen3-6-35b-a3b
    litellm_params:
      model: openai/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf
      api_base: http://llama-server.llm.svc.cluster.local:8080/v1
      api_key: "sk-noauth"
router_settings:
  model_group_alias:
    local-default: qwen3-8-27b
```

Переключение модели требует синхронной правки **двух** мест — `group_vars`
(`platform_aicd_devops_labs_ru_llm_active_model`) и LiteLLM values
(`router_settings.model_group_alias.local-default`) — рассинхрон между ними означает, что
`local-default` продолжит стучаться в Service модели, у которой `replicas: 0` (запросы будут
таймаутиться, а не вернут понятную ошибку).

## Хронология этой сессии

### Итерация 1 — mainline llama.cpp, `IQ2_XXS` (отклонено пользователем)

Первая попытка — тот же движок, что уже проверен для `Qwen3.6-35B-A3B` (ADR-0021), квант
`IQ2_XXS` (самый агрессивный, минимальный размер файла). Пользователь счёл качество квантования
неприемлемым для 27B-модели и попросил переосмыслить развёртывание после прочтения двух
комментариев на Habr (https://habr.com/ru/articles/1070694/, /comments/) про запуск того же
класса модели на идентичном железе (RTX 5060 Ti 16GB) через `ik_llama.cpp` с более качественным
квантом `IQ4_KS_KT` — рекомендацией сообщества было "трудности приемлемы, качество того стоит".

### Итерация 2 — `ik_llama.cpp` + `IQ4_KT` (`cHunter789/Qwen3.8-27B-i1-IQ4_KS_KT-GGUF`) — не взлетело

[`ik_llama.cpp`](https://github.com/ikawrakow/ik_llama.cpp) — форк `llama.cpp` с "SOTA quants"
(`IQ4_KS`, `IQ4_KT` — trellis-квантование) и рядом фич (MLA, fused delta-net, MTP), недоступных в
апстриме. По рекомендации из Habr-комментариев выбран `IQ4_KT` как компромисс размер/качество.
Разворачивание вскрыло **три независимых бага**, каждый диагностирован живым экспериментом до
перехода к следующей гипотезе:

**Баг 1 — SIGILL (exit 132) сразу после старта контейнера.** Официальный образ
`ghcr.io/ikawrakow/ik-llama-cpp` собран с `-DGGML_NATIVE=ON` (подтверждено README форка: "If you
build the image on a different machine, change -DGGML_NATIVE=ON to -DGGML_NATIVE=OFF") — то есть
бинарник скомпилирован под конкретный CPU билд-машины автора форка, без runtime-диспетчеризации
инструкций. На любом хосте без ровно того же набора инструкций — `SIGILL`.

Диагностика изначально пошла по ложному следу ("хост физически не поддерживает AVX2") — **пользователь
поправил**, прислав реальный `/proc/cpuinfo` хоста Proxmox (`Xeon E5-2666 v3`, Haswell, есть
`avx2`/`fma`). Причина оказалась не в железе, а в конфигурации Proxmox VM: `cpu:
x86-64-v2-AES` в `platform/aicd-devops-labs-ru/terraform/llm1-target.tf` — этот тип CPU не
экспонирует гостю AVX2, независимо от реальных возможностей физического процессора. Исправлено
пользователем через прямой Proxmox API-вызов (`cpu: host`, что Terraform не применяет сам —
`cpu`-блок под `lifecycle.ignore_changes`, см. комментарий в `llm1-target.tf`) — graceful shutdown
гостя → смена типа → boot. Подтверждено постфактум: гостевой `/proc/cpuinfo` после смены типа
показывает `avx avx2`, которых не было до этого (раньше гость видел `QEMU Virtual CPU version
2.5+`, только `sse sse2 sse4_1 sse4_2`, без единого AVX-флага).

**Баг 2 — SIGKILL (exit 137) прямо посреди реальной генерации.** После фикса CPU-типа модель
грузилась (65/65 слоёв на GPU, лог подтверждает ~12.78 ГБ буфера CUDA0), но контейнер убивался
ровно тогда, когда приходил реальный chat/completion запрос. Причина — в k8s-событиях: `Liveness
probe failed: ... context deadline exceeded`, следом `Killing: ... failed liveness probe`. Ни один
из трёх проб (`startupProbe`/`readinessProbe`/`livenessProbe`) не имел явного `timeoutSeconds` —
действовал дефолт Kubernetes в 1 секунду. `/health` под реальной генерацией отвечает с задержкой в
секунду-другую (обслуживающий поток занят инференсом) — 1-секундный таймаут ложно считал живой,
но занятый процесс нездоровым и убивал его прямо посреди выдачи ответа. Исправлено явным
`timeoutSeconds: 10` на всех трёх пробах (`site.yml`, роль `platform_aicd_devops_labs_ru_llm_*`).

**Баг 3 (финальный, не 100% доказанный, но не опровергнутый ни одним экспериментом) —
катастрофическая медленность prefill на кванте `IQ4_KT`.** После фиксов 1 и 2 прямой запрос к
backend (в обход LiteLLM) с тривиальным промптом (`"2+2="`, `max_tokens: 5`) всё равно таймаутился
после 30 секунд. Лог подтвердил: сам prefill тривиального промпта занимал полные 30+ секунд
(`kv cache rm [p0, end) p0=0` в 06:58:52.853, отмена клиентом в 06:59:22.852 — ровно 30с).
Проверенные и отклонённые гипотезы:

- LiteLLM подставляет гигантский системный промпт — опровергнуто прямым запросом к backend в
  обход LiteLLM (тот же результат).
- Механизм prompt-cache/chunked-checkpoint `ik_llama.cpp` пересчитывает контекст патологически —
  опровергнуто повторным тестом с `--cache-ram 0` (полностью отключает кэш) — та же медленность.

Рабочая (не опровергнутая) гипотеза: `IQ4_KT` ("trellis"-квантование) не имеет оптимизированного
CUDA-ядра под архитектуру Blackwell RTX 5060 Ti (compute capability 12.0 — очень новое на момент
реализации железо), из-за чего исполнение проваливается в generic-путь на порядки медленнее — это
объясняет одинаковую медленность независимо от размера промпта, проявляющуюся даже на 5 токенах
генерации.

По запросу пользователя ("покопаться глубже") искался чистый `IQ4_KS` (без `_KT`-компонента)
single-file GGUF для Qwen3.8-27B на HuggingFace — не найден в практичном формате. Единственный
существующий вариант — `Thireus/Qwen3.8-27B-THIREUS-IQ4_KS-SPECIAL_SPLIT` — формат из 852
tensor-level шардов, требующий кастомного `GGUF-Tool-Suite` для сборки, признан непрактичным для
простого curl-based fetch-механизма этой платформы. Пользователь подтвердил переход на mainline
`llama.cpp` как единственный оставшийся разумный вариант.

### Итерация 3 (финал) — mainline `llama.cpp` + `unsloth/Qwen3.8-27B-GGUF` `IQ3_XXS`

Тот же движок и образ, что уже проверен и стабилен для `Qwen3.6-35B-A3B`
(`ghcr.io/ggml-org/llama.cpp:server-cuda12-b11065`), тот же доверенный квантователь платформы
(`unsloth`), промежуточный по агрессивности квант `IQ3_XXS` (10.19 ГиБ) — заметно лучше, чем
отклонённый пользователем `IQ2_XXS`, и без риска engine-совместимости, который сгубил
`ik_llama.cpp`.

**Найденная при этом переключении проблема — PVC нельзя уменьшить.** PVC
`llm-weights-llama-server-qwen3-8-27b` был изначально создан на `20Gi` (под запас для более
крупного `ik_llama.cpp`-файла, 14.76 ГиБ). Значение `pvc_size: 15Gi` в `group_vars` (рассчитанное
под фактический размер `IQ3_XXS`, 10.19 ГиБ) при прогоне `site.yml` упало с ошибкой API
Kubernetes: `spec.resources.requests.storage: Forbidden: field can not be less than
status.capacity` — PVC можно только расширять, не сжимать. Исправлено — `pvc_size: 20Gi` в
`group_vars/platform_hosts.yml` зафиксировано под фактический живой размер, с явным комментарием
почему число больше теоретического минимума под текущий файл.

**Найденная при финальной закачке проблема — диск `llm1` забился мусором от предыдущей
попытки.** `fetch-weights`-initContainer не удаляет файлы прошлых попыток при смене
`gguf_file`/`gguf_repo` — на PVC остался файл от отклонённого `ik_llama.cpp`
(`Qwen3.8-27B.i1-IQ4_KT-attn_qkv-IQ4_KS.gguf`, 14.76 ГиБ). Суммарно с недокачанным `.tmp` новой
модели это забило корневой раздел `llm1` до 93% (54G/58G, свободно 4.6G), что вызвало:

1. Убийство самой закачки на середине (`fetch-weights` init-контейнер получил `exit 137`).
2. `node.kubernetes.io/disk-pressure:NoSchedule` taint на ноде `llm1` от kubelet'а — новый под не
   мог запланироваться вообще (`0/2 nodes are available: ... untolerated taint(s)`).

Исправлено вручную (по подтверждению пользователя): `sudo rm` двух файлов на `llm1`
(`/var/lib/rancher/k3s/storage/pvc-<uuid>_llm_llm-weights-llama-server-qwen3-8-27b/`), диск упал с
93% до 52% использования. **Taint снялся не сразу** — у kubelet'а есть
`--eviction-pressure-transition-period` (дефолт 5 минут): once узел помечен под давлением, taint
держится минимум 5 минут стабильно низкого использования, прежде чем снимется, во избежание
дребезга. После ожидания под успешно доскачал модель и стартовал.

**Общий вывод по этому классу проблем:** `fetch-weights`-скрипт (initContainer, `site.yml`) должен
либо переиспользовать один и тот же путь на PVC независимо от `gguf_file` (тогда старый файл
естественно перезаписывается при следующей закачке под тем же именем), либо явно чистить каталог
перед началом новой закачки при смене имени файла — сейчас этого не делает, что и стало корневой
причиной инцидента. Зафиксировано как техдолг, не исправлено в этой сессии (см. «Открытые
вопросы»).

## Финальная конфигурация

`platform/aicd-devops-labs-ru/ansible/group_vars/platform_hosts.yml`:

```yaml
platform_aicd_devops_labs_ru_llm_models:
  qwen3_8_27b:
    service_name: llama-server-qwen3-8-27b
    pvc_size: 20Gi   # см. §«PVC нельзя уменьшить» выше — не теоретический минимум
    image: "ghcr.io/ggml-org/llama.cpp:server-cuda12-b11065"
    gguf_repo: unsloth/Qwen3.8-27B-GGUF
    gguf_revision: 4ca720788d1e01f1bff70c033e0d0028fd02e502
    gguf_file: Qwen3.8-27B-UD-IQ3_XXS.gguf
    gguf_size_bytes: 10934860704
    mmproj_file: ""
    mmproj_size_bytes: 0
    extra_args: ["--ctx-size", "32768"]

platform_aicd_devops_labs_ru_llm_active_model: qwen3_8_27b
```

Пробы (`site.yml`, общие для всех моделей словаря — фикс из Итерации 2, Баг 2):

```yaml
startupProbe:   {httpGet: {path: /health, port: 8080}, periodSeconds: 10, timeoutSeconds: 10, failureThreshold: 90}
readinessProbe: {httpGet: {path: /health, port: 8080}, periodSeconds: 10, timeoutSeconds: 10, failureThreshold: 3}
livenessProbe:  {httpGet: {path: /health, port: 8080}, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 3}
```

Proxmox VM `llm1`: `cpu: host` (было `x86-64-v2-AES`), изменено вручную через Proxmox API,
Terraform `cpu`-блок под `lifecycle.ignore_changes` (не применяет и не откатывает это значение).

## Результат — живая верификация (2026-09-22)

Прямой запрос к backend (в обход LiteLLM):

```
POST http://llama-server-qwen3-8-27b.llm.svc.cluster.local:8080/v1/chat/completions
→ 200, 0.96с, {"content":"2 + 2 = 4"}
```

Через LiteLLM, псевдоним `local-default`:

```
POST https://litellm.aicd.devops-labs.ru/v1/chat/completions {"model":"local-default", ...}
→ 200, 0.57с, {"content":"2 + 2 = 4"}
```

Полный `ansible-playbook site.yml` дважды прогнан до конца (второй раз — после фикса
`pvc_size`) — все задачи `LLM:*`/LiteLLM/Open WebUI отработали идемпотентно (`ok`, без
незапланированных `changed`), единственный `changed` во втором прогоне — нормализация Deployment
`qwen3_8_27b` после серии ручных live-патчей `kubectl`-эквивалентом во время отладки (ожидаемо,
не баг). Итоговое состояние кластера полностью совпадает с кодом в `group_vars`/`site.yml`.

## Открытые вопросы / техдолг

- `fetch-weights`-initContainer не чистит файлы предыдущих попыток при смене `gguf_file` —
  причина инцидента с забитым диском выше. Не исправлено в этой сессии.
- Гипотеза о причине медленности `IQ4_KT` (отсутствие оптимизированного CUDA-ядра под compute
  capability 12.0) не подтверждена официально (нет апстрим-issue/ответа мейнтейнера
  `ik_llama.cpp`) — принята по совокупности косвенных признаков, методом исключения.
  `ik_llama.cpp` для этой платформы сейчас не используется вовсе.
- `Qwen3.8-27B-UD-IQ3_XXS` — не худший, но и не лучший доступный квант; если в будущем появится
  практичный (single-file) `IQ4`-класса квант с рабочим CUDA-ядром на этом GPU, есть смысл
  переоценить.
- Единовременно может быть активна только одна модель (общий GPU) — см. §«Архитектура» выше,
  осознанное ограничение, не решается программно без второго GPU.

## Ссылки

- `docs/adr/0021-agent-platform-model-selection.md` — исходное архитектурное решение (движок,
  первая модель `Qwen3.6-35B-A3B`), не переписан под архитектуру нескольких моделей.
- `platform/aicd-devops-labs-ru/ansible/group_vars/platform_hosts.yml` — пины моделей,
  подробные комментарии с историей итераций прямо в файле.
- `platform/aicd-devops-labs-ru/ansible/site.yml` — play "ADR-0021 — локальный инференс".
- `helm/values/platform-devops-labs-ru/namespaces/gateway/litellm/values.yaml` — `model_list` +
  `router_settings.model_group_alias`.
- `platform/aicd-devops-labs-ru/terraform/llm1-target.tf` — `cpu`-блок под
  `lifecycle.ignore_changes` (почему Terraform не видит и не откатывает смену CPU-типа).
- [`ik_llama.cpp` (ikawrakow)](https://github.com/ikawrakow/ik_llama.cpp) — форк с
  `IQ4_KS`/`IQ4_KT`, не используется в итоговой конфигурации.
- [`ggml-org/llama.cpp` releases](https://github.com/ggml-org/llama.cpp) — mainline движок,
  используется в итоговой конфигурации.
- Habr-комментарии, повлиявшие на итерацию 2: `https://habr.com/ru/articles/1070694/`,
  `https://habr.com/ru/articles/1070694/comments/`.
