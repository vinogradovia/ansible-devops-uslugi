#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: (c) 2022, DenAV <https://github.com/DenAV>
# Copyright: (c) 2026, Ivan Vinogradov <vinogradovia@gmail.com>
# SPDX-License-Identifier: MIT
#
# Ported from https://github.com/DenAV/nginx-proxy-manager-ansible
# (library/npm_proxy.py, MIT-licensed) for the reverse_proxy_npm role — see
# docs/adr/0001-reverse-proxy-npm-role.md, §3. HTTP calls were rewritten to use
# ansible.module_utils.urls.fetch_url instead of the third-party `requests`
# library, so the collection does not need a new controller-side pip dependency.

from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r'''
---
module: npm_proxy

short_description: manage Nginx Proxy Manager proxy hosts via its REST API

version_added: "1.0.0"

description: >-
    Creates or deletes a Nginx Proxy Manager (NPM) proxy host through its REST API.
    Used by the devops.uslugi.reverse_proxy_npm role to sync proxy hosts declared in
    inventory, instead of managing them by hand through the NPM web UI.

options:
    url:
        description: Base URL of the NPM REST API (e.g. C(http://127.0.0.1:81/api)).
        required: true
        type: str
    token:
        description: Bearer token obtained from C(POST {{ url }}/tokens).
        required: true
        type: str
    domain:
        description: Domain name of the proxy host.
        required: true
        type: str
    host:
        description: Forward hostname or IP address.
        required: true
        type: str
    host_port:
        description: Forward port.
        required: false
        default: 80
        type: int
    ssl_forced:
        description: Request a Let's Encrypt certificate and force SSL for this host.
        required: false
        default: false
        type: bool
    letsencrypt_email:
        description: >-
            Email address used for the Let's Encrypt certificate request.
            Required when I(ssl_forced=true).
        required: false
        default: ''
        type: str
    state:
        description: Whether the proxy host should exist (C(present)) or not (C(absent)).
        required: false
        type: str
        default: present
        choices:
          - absent
          - present
    validate_certs:
        description: Whether to validate TLS certificates when calling the NPM API.
        required: false
        default: true
        type: bool

author:
    - DenAV (@DenAV)
    - Ivan Vinogradov (@vinogradovia)
'''

EXAMPLES = r'''
- name: Create proxy host on NPM
  devops.uslugi.npm_proxy:
    url: "http://127.0.0.1:81/api"
    token: "{{ reverse_proxy_npm_login.json.token }}"
    domain: "app.example.com"
    host: "10.0.0.5"
    host_port: 8080
    ssl_forced: true
    letsencrypt_email: "admin@example.com"
    state: present

- name: Delete proxy host on NPM
  devops.uslugi.npm_proxy:
    url: "http://127.0.0.1:81/api"
    token: "{{ reverse_proxy_npm_login.json.token }}"
    domain: "app.example.com"
    host: "10.0.0.5"
    state: absent
'''

RETURN = r'''
msg:
  description: Human-readable result of the operation.
  returned: always
  type: str
  sample: "Proxy-host app.example.com created"
'''

import json

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.urls import fetch_url


def build_url(api_url, action, item_id=None):
    if action == "create-host":
        return "%s/nginx/proxy-hosts" % api_url, "POST"
    elif action == "search-host":
        return "%s/nginx/proxy-hosts" % api_url, "GET"
    elif action == "delete-host":
        return "%s/nginx/proxy-hosts/%s" % (api_url, item_id), "DELETE"
    elif action == "delete-ssl":
        return "%s/nginx/certificates/%s" % (api_url, item_id), "DELETE"
    raise ValueError("Unknown action: %s" % action)


def http_request(module, api_url, token, action, data=None, item_id=None, timeout=30):
    url, method = build_url(api_url, action, item_id)

    headers = {
        "Authorization": "Bearer %s" % token,
        "Content-Type": "application/json",
    }

    body = json.dumps(data) if data is not None else None

    response, info = fetch_url(
        module, url, data=body, headers=headers, method=method, timeout=timeout,
    )

    status_code = info["status"]
    if status_code == -1:
        module.fail_json(msg="Failed to reach %s: %s" % (url, info.get("msg", "unknown error")))

    raw_body = response.read() if response is not None else b""
    return raw_body, status_code


def search_proxy_host(module, api_url, token, domain_name):
    raw_body, status_code = http_request(module, api_url, token, action="search-host")

    if status_code >= 400:
        module.fail_json(msg="Failed to list proxy-hosts (HTTP %d): %s" % (status_code, raw_body))

    for item in json.loads(raw_body):
        if domain_name in item["domain_names"]:
            return item
    return None


def create_proxy_host(module, api_url, token, domain_name, forward_host, forward_port,
                       ssl_forced, letsencrypt_email=''):
    proxy_host = search_proxy_host(module, api_url, token, domain_name)
    if proxy_host:
        return 0, "Proxy-host %s already exists" % domain_name

    data = {
        "domain_names": [domain_name],
        "forward_host": forward_host,
        "forward_port": forward_port,
        "forward_scheme": "http",
        "allow_websocket_upgrade": True,
    }

    if ssl_forced:
        data["certificate_id"] = "new"
        data["ssl_forced"] = True
        if letsencrypt_email:
            data["meta"] = {
                "letsencrypt_email": letsencrypt_email,
                "letsencrypt_agree": True,
                "dns_challenge": False,
            }

    raw_body, status_code = http_request(
        module, api_url, token, action="create-host", data=data,
        timeout=120 if ssl_forced else 30,
    )

    if status_code == 201:
        return 1, "Proxy-host %s created" % domain_name

    return 2, "Failed to create proxy-host %s (HTTP %d): %s" % (domain_name, status_code, raw_body)


def delete_certificate(module, api_url, token, item_id):
    raw_body, status_code = http_request(module, api_url, token, action="delete-ssl", item_id=item_id)
    if status_code == 200:
        return 1, "Certificate id %s removed" % item_id
    return 2, "Failed to delete certificate id %s (HTTP %d): %s" % (item_id, status_code, raw_body)


def delete_proxy_host(module, api_url, token, domain_name):
    proxy_host = search_proxy_host(module, api_url, token, domain_name)
    if not proxy_host:
        return 0, "Proxy-host %s already absent" % domain_name

    if proxy_host.get('certificate_id'):
        rc, result = delete_certificate(module, api_url, token, item_id=proxy_host['certificate_id'])
        if rc == 2:
            return 2, "Failed to delete certificate for proxy-host %s: %s" % (domain_name, result)

    raw_body, status_code = http_request(
        module, api_url, token, action="delete-host", item_id=proxy_host['id'],
    )
    if status_code == 200:
        return 1, "Proxy-host %s removed" % domain_name
    return 2, "Failed to delete proxy-host %s (HTTP %d): %s" % (domain_name, status_code, raw_body)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            url=dict(type='str', required=True),
            token=dict(type='str', required=True, no_log=True),
            domain=dict(type='str', required=True),
            host=dict(type='str', required=True),
            host_port=dict(type='int', required=False, default=80),
            ssl_forced=dict(type='bool', required=False, default=False),
            letsencrypt_email=dict(type='str', required=False, default=''),
            state=dict(type='str', default='present', choices=['absent', 'present']),
            validate_certs=dict(type='bool', required=False, default=True),
        ),
    )

    api_url = module.params['url']
    token = module.params['token']
    domain_name = module.params['domain']

    if module.params['state'] == 'present':
        rc, result = create_proxy_host(
            module, api_url, token, domain_name,
            module.params['host'], module.params['host_port'],
            module.params['ssl_forced'], module.params['letsencrypt_email'],
        )
    else:
        rc, result = delete_proxy_host(module, api_url, token, domain_name)

    if rc == 2:
        module.fail_json(msg=result)
    module.exit_json(msg=result, changed=(rc == 1))


if __name__ == '__main__':
    main()
