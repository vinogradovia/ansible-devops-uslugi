# infra_dns

Настраивает [bind9](https://www.isc.org/bind/) как авторитетный DNS-сервер: forward- и
reverse-зоны, forwarders, ACL и параметры прослушивания — из декларативного списка зон в
inventory. Не разворачивает ничего в docker (обычный systemd-сервис из apt), зависимостей от
других ролей коллекции нет (`meta/main.yml`: `dependencies: []`).

## Обязательные шаги перед использованием

- `infra_dns_zones` — список зон (по умолчанию пустой, роль ничего не деплоит без явного
  списка). Для **reverse-зон** (`*.in-addr.arpa`/`*.ip6.arpa`) поле `soa_contact` **обязательно** —
  дефолт `hostmaster.<zone.name>` для reverse-зоны собрал бы несуществующий домен вида
  `hostmaster.30.20.10.in-addr.arpa`. Роль явно падает `assert`'ом в `tasks/deploy_zone.yml`,
  если `soa_contact` не задан для такой зоны (ROADMAP.md, P2-20). Для forward-зон `soa_contact`
  опционален.

## Пример конфигурации

```yaml
infra_dns_enabled: true

infra_dns_zones:
  - name: example.com
    soa_ns: sl-dns-01.example.com
    soa_contact: hostmaster.example.com      # опционально для forward-зон
    ns_records:
      - sl-dns-01.example.com.
    records:
      - { name: sl-dns-01, type: A, value: 10.20.30.240 }
      - { name: web-01,    type: A, value: 10.20.30.50 }
    include_hosts: true                      # опционально, дефолт — infra_dns_zone_default_include_hosts

  - name: 30.20.10.in-addr.arpa               # reverse-зона — soa_contact ОБЯЗАТЕЛЕН
    soa_ns: sl-dns-01.example.com
    soa_contact: hostmaster.example.com
    ns_records:
      - sl-dns-01.example.com.
    records:
      - { name: "240", type: PTR, value: sl-dns-01.example.com. }
```

Полная схема элемента `infra_dns_zones` (все опциональные поля с дефолтами) — см. комментарии в
`defaults/main.yml`.

## Прочие переменные верхнего уровня

- `infra_dns_forwarders` (дефолт `[8.8.8.8, 8.8.4.4]`), `infra_dns_recursion`,
  `infra_dns_dnssec_validation` — глобальные настройки `named.conf.options`.
- `infra_dns_listen_on` / `infra_dns_listen_on_v6`, `infra_dns_allow_query`,
  `infra_dns_allow_transfer` — ACL-уровня опции (по умолчанию `allow_transfer: none` — зонный
  трансфер закрыт, пока явно не разрешён).
- `infra_dns_zone_dir` (`/etc/bind/master`) — каталог зона-файлов.
- `infra_dns_zone_default_*` — дефолты TTL/SOA-таймингов и `include_hosts` для зон, не
  переопределивших их явно.

## Molecule

`extensions/molecule/infra_dns/` — одноразовая ВМ (`driver: vagrant`/`libvirt`,
`cloud-image/ubuntu-24.04`). Converge покрывает одну forward-зону
(`dns.molecule.test`, дефолтный `soa_contact`) и одну reverse-зону
(`10.10.10.in-addr.arpa`, явный `soa_contact`, `include_hosts: false`). `verify.yml` гоняет
реальные `named-checkconf`/`named-checkzone` на задеплоенном конфиге и зона-файлах, плюс
функциональные `dig`-запросы (A, CNAME, `-x`/PTR).
