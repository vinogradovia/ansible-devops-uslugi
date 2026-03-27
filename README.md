# Ansible Collection - devops.uslugi

## Linter

```bash
ansible-lint
```


# Monitoring Server


## VMScrape


## VMAlert

для k3s управление осуществляется через ресурс VMRules.

Создание и удаление русурсов осуществляется напрямую через ansible, без использования heml

Запуск тасок по настройке алертов:

```bash
ansible-playbook -i inventory.yml monitoring-server.yml \
    --tags monitoring_server_victoria_metrics_exporter_alerts
```

Для каждого exporter в роли monitoring_server определена переменная:
`monitoring_server_victoria_metrics_alerts_rules_*exporter_name*_default:`

и предопределены файлы, из которых подгружаются тексты для `VMRule`


Пример элемента предопределенного массива `monitoring_server_victoria_metrics_exporters` с настройками экспортеров и алертов:
```yaml
  - name: node-exporter
    scrape_src: victoria-metrics-scrape-node-exporter-targets.json.j2
    scrape_dest: "{{ monitoring_server_victoria_metrics_config_dir }}/scrape_config/node_exporter_targets.json"
    scrape_state: "{{ monitoring_server_victoria_metrics_scrape_node_exporter }}"
    alert_rules_default_enabled: "{{ monitoring_server_victoria_metrics_alerts_rules_node_exporter_default }}"
    alert_rules_src:
      - "alert-rules/node-exporter.yml"
```

### Добавление нового экспортера:

* создать файл(ы) с алертами в каталоге `monitoring_server/templates/alert-rules/new-exporter.yml`
* создать дефолтные переменные для роли сервера в `monitoring_server/default/main.yml`
    * `monitoring_server_victoria_metrics_scrape_new_exporter`
    * `monitoring_server_victoria_metrics_scrape_new_exporter_port_default`
    * `monitoring_server_victoria_metrics_alerts_rules_new_exporter_default`
* создать дефолтные переменные для роли агента  в `monitoring_agent/default/main.yml`
    * `monitoring_agent_new_exporter_enabled`
    * `monitoring_agent_new_exporter_image_registry`
    * `monitoring_agent_new_exporter_image_repository`
    * `monitoring_agent_new_exporter_image_version`
    * `monitoring_agent_new_exporter_image`
    * `monitoring_agent_new_exporter_port`
    * `monitoring_agent_new_exporter_systemd_name`
    * `monitoring_agent_new_exporter_binary_download_url`
    * `monitoring_agent_new_exporter_binary_install_path`
* добавить новый элемент массива `monitoring_server_victoria_metrics_exporters` в `monitoring_server/vars/main.yml`
