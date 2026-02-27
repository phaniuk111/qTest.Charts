{{/*
Common labels
*/}}
{{- define "qtest-elasticsearch.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Selector labels — used in matchLabels (must NOT change between upgrades)
*/}}
{{- define "qtest-elasticsearch.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Build the seed_hosts list for master discovery.
Produces: "qtest-elasticsearch-master-0.qtest-elasticsearch-master-headless.qtest.svc.cluster.local", "..."
Each entry is individually quoted for ES YAML list syntax.
*/}}
{{- define "qtest-elasticsearch.seedHosts" -}}
{{- $name := printf "%s-master" .Values.service.name -}}
{{- $ns := .Values.namespace.name -}}
{{- $replicas := int .Values.master.replicas -}}
{{- $hosts := list -}}
{{- range $i := until $replicas -}}
  {{- $hosts = append $hosts (printf "\"%s-%d.%s-headless.%s.svc.cluster.local\"" $name $i $name $ns) -}}
{{- end -}}
{{ join ", " $hosts }}
{{- end }}

{{/*
Build initial_master_nodes list (node names, not hostnames).
Produces: "qtest-elasticsearch-master-0", "qtest-elasticsearch-master-1"
*/}}
{{- define "qtest-elasticsearch.initialMasterNodes" -}}
{{- $name := printf "%s-master" .Values.service.name -}}
{{- $replicas := int .Values.master.replicas -}}
{{- $nodes := list -}}
{{- range $i := until $replicas -}}
  {{- $nodes = append $nodes (printf "\"%s-%d\"" $name $i) -}}
{{- end -}}
{{ join ", " $nodes }}
{{- end }}
