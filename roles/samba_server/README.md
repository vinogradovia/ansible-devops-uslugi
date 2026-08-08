# samba_server

Простая роль для организации общего файлового хранилища на базе [Samba](https://www.samba.org/):
локальные Unix/Samba-пользователи + список шар, авторизация `security = user` (smbpasswd).

## Назначение

Минималистичная альтернатива для случаев, когда нужен обычный SMB-шаринг файлов (Windows/macOS/
Linux клиенты в LAN), а не полноценный AD DC или NAS-решение. Не покрывает: Active Directory,
Samba VFS-модули (recycle bin, shadow copies и т.п.), квоты, ACL поверх POSIX-прав — только базовый
`[global]` + список `[share]`-секций.

## Аутентификация

Единственный поддерживаемый режим — `security = user` (переменная `samba_server_security`,
менять не рекомендуется). Пользователи заводятся ролью как системные Unix-аккаунты
(`samba_server_users`) и получают Samba-пароль через `smbpasswd` (пароль передаётся в команду
через stdin, `no_log: true` — в командную строку процесса и в smb.conf не попадает). Гостевой
доступ включается точечно на уровне конкретной шары (`guest_ok: true`), а не глобально.

**Пароли пользователей обязаны приходить из ansible-vault** (`samba_server_users[].password`) —
роль падает на этапе `Validate samba_server_users`, если пароль не задан.

## Переменные

См. полный список с комментариями в [`defaults/main.yml`](defaults/main.yml). Ключевые:

- `samba_server_workgroup`, `samba_server_server_string`, `samba_server_netbios_name` —
  идентификация сервера в сети.
- `samba_server_users` — список `{name, password, uid, groups}`.
- `samba_server_shares` — список шар: `{name, path, comment, valid_users, write_list, read_only,
  guest_ok, browsable, owner, group, directory_mode, create_mask, directory_mask}`. Каталог
  `path` создаётся ролью, если ещё не существует.

## Права на запись: SMB-уровень и уровень ОС — это два разных, независимых слоя

`valid_users`/`write_list`/`read_only` в smb.conf разрешают операцию только на уровне SMB-
протокола. Дальше Samba выполняет файловую операцию от имени подключившегося Unix-пользователя
(роль не настраивает `force user`/`force group`) — и права на каталог (`owner`/`group`/
`directory_mode`) проверяются независимо, штатным способом ОС. Если пользователь не входит в
группу-владельца каталога, `write_list` его не спасёт: SMB разрешит запись, а ядро — откажет.

Рабочий паттерн: заведите пользователям, которым нужна запись, общую доп. группу через
`samba_server_users[].groups` (роль создаст группу, если её ещё нет) и назначьте эту же группу
владельцем каталога шары (`samba_server_shares[].group`) с `directory_mode` вида `"2775"` (setgid
— новые файлы наследуют группу каталога, а не группу автора). Пример ниже.

## Пример

```yaml
- hosts: samba_servers
  roles:
    - role: devops.uslugi.samba_server
      samba_server_workgroup: OFFICE
      samba_server_users:
        - name: alice
          password: "{{ vault_samba_alice_password }}"
          groups: [sambashare]
        - name: bob
          password: "{{ vault_samba_bob_password }}"
          groups: [sambashare]
      samba_server_shares:
        - name: shared
          path: /srv/samba/shared
          comment: "Общее хранилище"
          valid_users: [alice, bob]
          read_only: false
          group: sambashare
          directory_mode: "2775"
        - name: public
          path: /srv/samba/public
          comment: "Публичная шара для чтения"
          guest_ok: true
          read_only: true
```

## Что роль не делает

- Не настраивает firewall (ufw/iptables) — порты 445/139 (и 137/138 UDP для NetBIOS/nmbd)
  открывайте отдельно, если это требуется в вашей сетевой политике.
- Не устанавливает `winbind`/`sssd` и не интегрируется с Active Directory.
