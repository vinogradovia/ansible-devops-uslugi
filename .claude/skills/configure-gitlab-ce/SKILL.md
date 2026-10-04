---
name: configure-gitlab-ce
description: >-
  Knowledge of the specific chain of TLS and DNS failures that show up when running
  self-hosted GitLab CE (Omnibus) with self-signed certificates behind gitlab-agent
  and/or gitlab-runner, especially when the runner/agent runs inside Kubernetes (k3s
  or similar). Covers why Go-based GitLab clients reject self-signed certs that
  browsers/openssl accept, why Omnibus's own trust-store mechanism sometimes isn't
  enough, why nginx can silently keep serving a stale certificate after you regenerate
  it, why two independently-generated self-signed certs with the same CommonName (e.g.
  one on GitLab itself and another on a reverse-proxy in front of it) confuse Go's
  certificate-pool verification even when both are individually valid, and why DNS that
  resolves correctly on a host still fails inside a Kubernetes pod. Use this skill
  proactively whenever the user is deploying, reconfiguring, or
  debugging GitLab CE with a self-signed cert, setting up the GitLab Kubernetes Agent
  (KAS/agentk) or GitLab Runner's kubernetes executor, or troubleshooting gRPC/TLS
  "Unavailable" errors, "x509: certificate signed by unknown authority", "crypto/rsa:
  verification error", or intermittent NXDOMAIN for an internal DNS zone from inside a
  Kubernetes cluster — even if the user doesn't mention GitLab by name and just
  describes one of these symptoms.
---

# Настройка GitLab CE с self-signed TLS для gitlab-agent / gitlab-runner

## Зачем этот скилл

GitLab Kubernetes Agent (KAS/agentk) и GitLab Runner оба написаны на **Go**. Стандартный
`crypto/x509` в Go заметно строже OpenSSL и браузеров к тому, что считается валидным
certificate authority. Когда GitLab развёрнут самостоятельно с self-signed сертификатом
(обычный случай для внутренних/лабораторных окружений без настоящего CA), эта строгость
порождает цепочку запутанных ошибок, каждая из которых выглядит как отдельный баг, но на
самом деле это три-четыре отдельные, хорошо изученные проблемы, наложенные друг на друга. Этот
скилл существует, чтобы не переоткрывать каждую из них методом проб и ошибок — каждый раздел
ниже — это симптом, который можно сопоставить с логами, с указанием причины и фикса.

Второй сквозной мотив — DNS: то, что имя резолвится корректно при проверке с хоста, не значит,
что оно резолвится корректно из под'а Kubernetes. Собственное слоение DNS в Kubernetes
(kubelet → CoreDNS → резолвер ноды) теряет информацию, на которую опираются хостовые средства
типа `systemd-resolved`, из-за чего фиксы DNS, которые выглядят завершёнными, молча не долетают
до workload'ов внутри кластера.

Проходите разделы по порядку — они опираются друг на друга, и сообщение об ошибке, которое вы
видите, часто относится к *предыдущему* нерешённому слою, а не к тому, на который вы сейчас
смотрите.

## 1. Go отвергает self-signed сертификаты без `CA:TRUE`

**Симптом:** в логах gitlab-agent или gitlab-runner что-то вроде:

```
x509: invalid signature: parent certificate cannot sign this kind of certificate
```

**Причина:** типичный self-signed сертификат, сгенерированный "простым" способом (например,
`community.crypto.x509_certificate` с `provider: selfsigned`, или `openssl req -x509` без
дополнительных флагов) — это обычный leaf-сертификат, он не выставляет расширение
`basicConstraints: CA:TRUE`. Браузеры и дефолтный режим верификации OpenSSL не требуют от
self-signed root'а быть "настоящим" CA, чтобы доверять ему, а вот построитель цепочки в Go —
требует: когда он ищет сертификат для проверки подписи, он смотрит на `IsCA` у кандидата, и
self-signed leaf без этого флага падает с запутанным сообщением "parent certificate cannot
sign this kind of certificate".

**Фикс:** генерировать self-signed сертификат с явной возможностью быть CA:

```yaml
- name: Сгенерировать CSR с CA:TRUE
  community.crypto.openssl_csr:
    path: /path/to/cert.csr
    privatekey_path: /path/to/key.pem
    common_name: your.domain.tld
    basic_constraints:
      - "CA:TRUE"
    basic_constraints_critical: true
    key_usage:
      - keyCertSign
      - cRLSign
      - digitalSignature
    key_usage_critical: true

- name: Самоподписать (долгий срок — почему короткоживущие сертификаты — ловушка, см. §4)
  community.crypto.x509_certificate:
    path: /path/to/cert.pem
    privatekey_path: /path/to/key.pem
    csr_path: /path/to/cert.csr
    provider: selfsigned
    selfsigned_not_after: "+3650d"
```

Если GitLab Omnibus успел автоматически сгенерировать свой сертификат раньше (а он это
делает по умолчанию, как только `external_url` становится `https://`), этот автосгенерированный
сертификат **тоже** без `CA:TRUE` и **тоже** требует замены — см. §4 про ловушку
идемпотентности, которую это создаёт.

## 2. То, что nginx отдаёт правильный сертификат — не значит, что его достаточно: у KAS свой trust store

**Симптом:** внешний TLS-хендшейк теперь проходит (agent/runner проходят DNS-резолв и первую
проверку сертификата), но собственные логи KAS (`/var/log/gitlab/gitlab-kas/current` на
Omnibus) показывают падение на *его собственном* обратном вызове к GitLab API:

```
Get "https://your.domain.tld/api/v4/internal/agents/agentk/agent_info":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Причина:** KAS (`gitlab-kas`) — отдельный от nginx/Rails ОС-процесс, со своим собственным
HTTP-клиентом и своим собственным trust store сертификатов (`SSL_CERT_DIR`/`SSL_CERT_FILE`).
Фикс отдаваемого nginx сертификата никак не влияет на *исходящие* вызовы KAS на этот же URL —
ему нужно отдельно начать доверять сертификату.

**Фикс, в порядке предпочтения:**

1. Штатный механизм Omnibus: положить сертификат в `/etc/gitlab/trusted-certs/` и выполнить
   `gitlab-ctl reconfigure`. По документации это должно распространиться в trust store каждого
   внутреннего компонента через hash-именованный symlink в `/opt/gitlab/embedded/ssl/certs/`.
2. Если этого не хватает (см. §3, почему иногда не хватает), задать trust store явно только
   для процесса KAS через `gitlab.rb`:
   ```ruby
   gitlab_kas['env'] = {
     'SSL_CERT_FILE' => '/etc/gitlab/ssl/your.domain.tld.crt'
   }
   ```
   Указание ровно на один файл вместо опоры на общий системный пул убирает любую
   неоднозначность в том, какой кандидат выберет загрузчик Go.

## 3. `crypto/rsa: verification error` почти всегда значит, что nginx отдаёт *другой* сертификат, чем тот, что вы проверяли на диске

**Симптом:** вы сделали §1 и §2, у сертификата на диске точно есть `CA:TRUE`
(`openssl x509 -noout -text` подтверждает), `openssl verify` против trust-директории говорит
`OK` — и всё равно KAS падает с:

```
x509: certificate signed by unknown authority (possibly because of
"crypto/rsa: verification error" while trying to verify candidate authority
certificate "your.domain.tld")
```

Это самая обманчивая ошибка во всей цепочке, потому что она *выглядит* как проблема с
криптографической структурой сертификата. Практически никогда это не так.

**Причина:** `gitlab-ctl reconfigure` перезапускает/перечитывает nginx только тогда, когда
меняется **сгенерированный конфиг nginx** (то есть когда меняется настройка в `gitlab.rb`,
влияющая на шаблон конфига). Если `nginx['ssl_certificate']` уже указывал на тот же *путь* в
предыдущем прогоне, а вы просто перегенерировали *содержимое файла* по этому пути (например,
потому что удалили и пересоздали сертификат, чтобы добавить `CA:TRUE`), reconfigure видит "конфиг
не изменился" и **не** перезапускает nginx. Воркеры nginx продолжают отдавать из памяти
**старый** сертификат, пока все файлы trust store, которые вы проверяете на диске — уже
**новые**. KAS (или agent) в итоге пытается проверить живой сертификат против доверенного
якоря, сгенерированного из другой пары ключей — естественно, подпись не проходит проверку.

**Как подтвердить, что именно это происходит** (сделайте это прежде, чем гнаться за любой
другой теорией):

```bash
# Что реально на диске:
openssl x509 -in /path/to/cert.pem -noout -serial

# Что реально отдаётся по проводу:
openssl s_client -connect 127.0.0.1:443 -servername your.domain.tld </dev/null 2>/dev/null \
  | openssl x509 -noout -serial
```

Если эти два serial'а отличаются — вот и вся проблема целиком. Больше ничего в сертификате не
важно, пока они не совпадут.

**Фикс:**

- Немедленно: `gitlab-ctl restart nginx` (не просто `reconfigure`).
- На постоянной основе, в плейбуке: добавить явный `notify` на саму задачу генерации
  сертификата (не только на задачи правки строк `gitlab.rb`), указывающий на handler,
  который делает `gitlab-ctl restart nginx`, идущий *после* handler'а `gitlab-ctl reconfigure`
  (Ansible выполняет notified handlers в порядке их объявления, а не в порядке notify —
  reconfigure должен разложить новый конфиг раньше, чем nginx перезапустится в него).
- После любой перегенерации сертификата — повторить шаги trust store из §2 тоже: любое
  значение, вычисленное из "сертификата на диске" (значение Helm `kasCaCert`, k8s Secret
  `certsSecretName`, копия в `trusted-certs`) было собрано по снимку на момент времени и теперь
  устарело относительно того, что реально отдаётся. Снимайте живым TLS-коннектом через
  `openssl s_client`, а не повторным чтением файла, и применяйте заново.

## 4. Следствие: не давайте Omnibus автогенерировать сертификат первым

Omnibus автоматически генерирует self-signed сертификат при первом же `external_url` на
`https://`, если `nginx['ssl_certificate']` не задан — и у этого автосгенерированного
сертификата обычно **короткий срок действия** (часто ~30 дней) и нет `CA:TRUE`. Если дать этому
случиться до применения фикса из §1, собственная задача генерации CSR будет молча пропущена
проверкой идемпотентности `exists` (поскольку *какой-то* файл уже есть), и будет отдаваться
сертификат, который сам скоро истечёт *и* не проходит проверку Go. Генерируйте свой сертификат
и указывайте `nginx['ssl_certificate']`/`['ssl_certificate_key']` на него с самого начала, либо
явно удаляйте автосгенерированные файлы перед запуском собственной задачи генерации.

## 5. Фикс DNS на уровне хоста не гарантирует, что он долетит до сервиса

Если имя хоста GitLab резолвится только через внутренний DNS-сервер (не через публичный
резолвер, который хосты получают по DHCP), нужно заставить ОС направлять запросы к этому
конкретному домену на внутренний резолвер — и соблазнительно сделать это одной глобальной
настройкой `DNS=`. В основном это не работает.

**Симптом:** `resolvectl query your.domain.tld` с самого хоста GitLab/runner работает, но
всё, что использует DHCP-резолвер напрямую, нестабильно возвращает `NXDOMAIN` для того же
самого имени.

**Причина:** в `systemd-resolved` **per-link** DNS-серверы (те, что назначил DHCP-клиент для
сетевого интерфейса) приоритетнее **глобального** fallback `DNS=` в
`/etc/systemd/resolved.conf.d/*.conf`. Простой `DNS=10.x.x.x` без привязки к домену
учитывается только тогда, когда ни у одного линка нет своих серверов — что не ваш случай, если
DHCP что-то назначил.

**Фикс:** использовать *routing domain*, которая создаёт явную привязку домен→сервер,
приоритетную над обычными per-link серверами для подходящих запросов, не трогая резолв всего
остального:

```ini
[Resolve]
DNS=10.x.x.x
Domains=~your.internal.zone
```

(Префикс `~` помечает её как routing-only — "отправлять запросы с этим суффиксом на этот
сервер" — а не как search-суффикс, который дописывается к неполным именам.)

## 6. Фикс DNS на уровне хоста из §5 не долетает до workload'ов в Kubernetes

Это тот случай, который стоит больше всего времени отладки, потому что выглядит так, будто §5
"должен был" всё решить, и с хоста это действительно так.

**Симптом:** `resolvectl query your.domain.tld` на **ноде** Kubernetes работает и стабилен.
Под, работающий на этой же ноде, иногда получает `NXDOMAIN` для того же самого имени — может,
1 раз из 3.

**Причина:** kubelet генерирует DNS-конфиг, видимый подам (и собственный upstream-конфиг
CoreDNS, поскольку под CoreDNS обычно использует `dnsPolicy: Default`, чтобы читать реальный
хостовой резолвер), из `/run/systemd/resolve/resolv.conf` — **плоского списка** всех upstream
nameserver'ов, известных systemd-resolved. У плоского `resolv.conf` нет синтаксиса для "сервер
A только для домена X, сервер B для всего остального" — поэтому routing domain из §5 здесь
невидима; kubelet просто видит "три nameserver'а" (ваш внутренний плюс что выдал DHCP). Плагин
`forward` в CoreDNS по умолчанию выбирает между несколькими upstream'ами с `policy random` —
поэтому примерно каждый N-ный запрос уходит на общие резолверы, которые (будучи настоящими
рекурсивными резолверами) не зависают по таймауту, а уверенно отвечают `NXDOMAIN` для имени, о
котором они реально никогда не слышали. Это выглядит как "нестабильно" и "случайно", потому что
буквально случайно — по каждому отдельному запросу.

**Фикс:** не пытайтесь фиксить это через resolv.conf ноды вообще — настройте CoreDNS напрямую
отдельным server-блоком именно под эту зону. В k3s это механизм ConfigMap `coredns-custom`,
не требующий правок основного Corefile:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  your-zone.server: |
    your.internal.zone:53 {
        forward . 10.x.x.x
    }
```

Примените его, затем перезапустите деплоймент CoreDNS, чтобы он подхватил новый custom-блок
(`kubectl -n kube-system rollout restart deployment coredns`). Проверяйте *из-под пода*
несколько раз подряд (обычно достаточно 5-6 раз, чтобы поймать нестабильность от
`policy random`), а не доверяя одному успешному запросу:

```bash
for i in 1 2 3 4 5 6; do
  kubectl exec <any-pod> -- nslookup your.domain.tld
done
```

Если вы разворачиваете это через Ansible вместе с Helm-релизами, зависящими от корректного
резолва (например, gitlab-agent, gitlab-runner) — применяйте ConfigMap и перезапуск CoreDNS как
задачу с `ansible.builtin.meta: flush_handlers` немедленно после неё, *до* любого шага
установки Helm в том же плее — иначе первая попытка установки обгонит CoreDNS, который ещё не
подхватил фикс, не зарегистрируется, и потребует ручного перезапуска пода после, чтобы
повторить попытку.

## 7. Особенности helmwave (если используете его)

Если вы разворачиваете через [helmwave](https://helmwave.github.io/), а не через обычный
`helm`, два флага из "очевидного вызова" на самом деле не существуют в 0.42.x и падают громко,
но непонятно:

- `helmwave up --build --yes ...` → `flag provided but not defined: -yes`. Подтверждать
  запуск нечего, подавлять не нужно — просто убрать флаг.
- `helmwave up --build --file helmwave.wave.yml` сам по себе, без предварительного
  `helmwave yml --tpl helmwave.yml.tpl --file helmwave.wave.yml`, падает с
  `failed to read plan file ...: no such file or directory`. `--build` собирает **план**
  (тянет чарты/values, рендерит манифесты) из уже отрендеренного `.yml`-файла — он не
  рендерит сам `.yml` из `.tpl`. Сначала запустить `helmwave yml`, затем `helmwave up --build`.

## 8. Два независимых self-signed сертификата с одинаковым CN за реверс-прокси путают Go ещё раз

Этот кейс всплывает на следующем шаге после §1-§4, когда перед GitLab ставят reverse-proxy
(nginx, Traefik и т.п.) как единую точку входа вместо прямого доступа к самому GitLab —
например, чтобы завести один внешний домен на несколько внутренних сервисов. Выглядит так,
будто вы уже всё сделали правильно: оба сертификата — и на самом GitLab (§1), и на
reverse-proxy — сгенерированы с `CA:TRUE`, serial'ы совпадают с тем, что реально отдаётся
(§3 пройден), а KAS всё равно падает:

```
x509: certificate signed by unknown authority
```

**Причина:** если на reverse-proxy сгенерировать *свою* независимую self-signed пару
ключ+сертификат для того же самого `CommonName` (естественное желание — у него такой же
домен, зачем копировать сертификат с другого хоста), то в итоге существуют **два разных**
self-signed сертификата с одинаковым Subject `CN=your.domain.tld`, но с разными ключевыми
парами. Это классическая проблема Go-x509 с bundle-пулами: когда в пуле доверенных
сертификатов есть несколько кандидатов с одинаковым Subject, построитель цепочки может
выбрать не того кандидата для проверки подписи конкретного пришедшего сертификата — и подпись,
естественно, не сойдётся, с той же обманчивой ошибкой "unknown authority", что и в §3, хотя
оба сертификата сами по себе корректны.

**Фикс:** не генерировать вторую независимую пару ключей на то же имя. Если домен уже
обслуживается самим GitLab с self-signed сертификатом (§1), **зеркалировать** этот же
сертификат+ключ на reverse-proxy, а не создавать новый:

```yaml
- name: "Забрать сертификат+ключ с GitLab"
  ansible.builtin.slurp:
    src: "/etc/gitlab/ssl/your.domain.tld.{{ item }}"
  loop: ["crt", "key"]
  register: cert_key_raw
  delegate_to: "{{ groups['gitlab_hosts'][0] }}"

- name: "Разложить тот же сертификат+ключ на reverse-proxy"
  ansible.builtin.copy:
    dest: "/etc/nginx/ssl/your.domain.tld/{{ 'fullchain.pem' if item.item == 'crt' else 'privkey.pem' }}"
    content: "{{ item.content | b64decode }}"
    mode: "{{ '0644' if item.item == 'crt' else '0640' }}"
  loop: "{{ cert_key_raw.results }}"
  notify: reload nginx
```

Тогда обе стороны — и KAS (который доверяет сертификату, снятому с самого GitLab), и
gitlab-agent/gitlab-runner (которые доверяют тому, что реально сняли живым TLS-коннектом,
см. §3) — видят буквально один и тот же сертификат независимо от того, через какой хост
физически прошёл запрос. Один сертификат на одно доменное имя — не два разных с одинаковым
CN — устраняет саму возможность неоднозначности для Go.

Если вы ставите reverse-proxy как единую точку входа для нескольких внутренних HTTP(S)-
сервисов, заодно проверьте, что сам reverse-proxy умеет проксировать WebSocket (для
`wss://.../kubernetes-agent/`, на который ходит gitlab-agent) — без явного включения этого в
конфиге прокси хендшейк падает на уровне HTTP с кодом 426 вместо ожидаемого 101.

## Чек-лист отладки (самый быстрый путь через всё вышеперечисленное)

Когда gitlab-agent или gitlab-runner не могут подключиться к самостоятельно развёрнутому
GitLab с self-signed сертификатом, проверяйте в этом порядке — симптом на каждом шаге
указывает, какой раздел выше применим:

1. `kubectl exec <pod> -- nslookup <gitlab-hostname>` — запустить несколько раз. Нестабильно →
   §6. Стабильно не работает → сначала фикс DNS на уровне хоста (§5), потом вернуться сюда.
2. `openssl x509 -in <сертификат-на-диске> -noout -text | grep -A2 "Basic Constraints"` — нет
   `CA:TRUE` → §1 (и проверить §4 на ловушку идемпотентности перед перегенерацией).
3. Сравнить serial'ы: файл на диске vs. `openssl s_client -connect 127.0.0.1:443
   -servername <hostname> </dev/null 2>/dev/null | openssl x509 -noout -serial`.
   Не совпадают → §3 (перезапустить nginx, затем повторить все следующие по цепочке шаги,
   которые читали старый сертификат).
4. Проверить `/var/log/gitlab/gitlab-kas/current` (или логи пода runner'а) на *точный* текст
   ошибки — "unknown authority" / "crypto/rsa", указывающий на собственный исходящий вызов KAS
   (не на входящий хендшейк клиента) → §2.
5. §1-§4 пройдены, serial'ы из п.3 совпадают, но ошибка "unknown authority" всё ещё есть, а в
   инфраструктуре есть reverse-proxy перед GitLab → проверить, не сгенерирована ли у прокси
   *своя независимая* self-signed пара на тот же CN → §8.
