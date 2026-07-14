---
project: monitoring
version: "0.42.4"

{{- $K8S_CLUSTER := requiredEnv "K8S_CLUSTER" }}
{{- $K8S_CLUSTER_ENTITIES := print "envs/" $K8S_CLUSTER ".yaml" }}

repositories:
{{- with readFile "envs/_helm-repos.yaml" | fromYaml | get "repositories" }}
{{- range $repo := . }}
  - name: {{ $repo | get "name" }}
    url: {{ $repo | get "url" }}
{{- end }}
{{- end }}
{{- with readFile $K8S_CLUSTER_ENTITIES | fromYaml | get "repositories" }}
{{- range $repo := . }}
  - name: {{ $repo | get "name" }}
    url: {{ $repo | get "url" }}
{{- end }}
{{- end }}

registries:
{{- with readFile "envs/_helm-repos.yaml" | fromYaml | get "registries" }}
{{- range $repo := . }}
  - host: {{ $repo | get "host" }}
    {{- if $repo.username }}
    username: {{ $repo | get "username" }}
    password: {{ $repo | get "password" }}
    {{- end }}
{{- end }}
{{- end }}
{{- with readFile $K8S_CLUSTER_ENTITIES | fromYaml | get "registries" }}
{{- range $repo := . }}
  - host: {{ $repo | get "host" }}
    {{- if $repo.username }}
    username: {{ $repo | get "username" }}
    password: {{ $repo | get "password" }}
    {{- end }}
{{- end }}
{{- end }}

.options: &options
  create_namespace: true
  wait: true
  timeout: 15m
  max_history: 10
  strict: true
  pending_release_strategy: rollback

releases:
{{- with readFile $K8S_CLUSTER_ENTITIES | fromYaml | get "releases" }}
{{- range $release := . }}
  - name: {{ $release | get "name" }}
    namespace: {{ $release | get "namespace" }}
    chart:
      name: {{ $release | get "chart" }}
      version: {{ $release | get "version" }}
    <<: *options
    values:
      - src: values/releases_common/{{ $release | get "name" }}.yaml
        strict: true
        delimiter_left: "[["
        delimiter_right: "]]"
      - src: values/{{ $K8S_CLUSTER }}/namespaces/{{ $release | get "namespace" }}/{{ $release | get "name" }}/values.yaml
        strict: false
        delimiter_left: "[["
        delimiter_right: "]]"
      {{- if $release.values }}
      {{ range $value_file := $release | get "values" }}
      - src: values/{{ $K8S_CLUSTER }}/namespaces/{{ $release | get "namespace" }}/{{ $release | get "name" }}/{{ print $value_file }}
        strict: true
        delimiter_left: "[["
        delimiter_right: "]]"
      {{- end }}
      {{ end }}
    tags:
      - {{ $release | get "name" }}
      - {{ $release | get "namespace" }}/{{ $release | get "name" }}
      {{- if $release.tags }}
      {{ range $tag := $release | get "tags" }}
      - {{ print $tag }}
      {{- end }}
      {{ end }}
    {{- if $release.depends_on }}
    depends_on:
      {{- range $dep := $release | get "depends_on" }}
      - {{- if $dep.name }} name: {{ $dep | get "name" }}
        {{- end }}
        {{- if $dep.tag }} tag: {{ $dep | get "tag" }}
        {{- end }}
        {{- if $dep.optional }} optional: {{ $dep | get "optional" }}
        {{- end }}
      {{- end }}
    {{- end }}
{{- end }}
{{- end }}
