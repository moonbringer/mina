### Mina Archive-Node healthcheck TEMPLATES ###

{{/*
archive-node startup probe settings
*/}}
{{- define "healthcheck.archive.startupProbe" }}
startupProbe:
  tcpSocket:
    port: archive-postgres-port
{{- end }}

{{/*
archive-node liveness check settings
*/}}
{{- define "healthcheck.archive.livenessCheck" }}
livenessProbe:
  tcpSocket:
    port: archive-server-port
{{- include "healthcheck.common.settings" . | indent 2 }}
{{- end }}

{{/*
archive-node readiness check settings
*/}}
{{- define "healthcheck.archive.readinessCheck" }}
readinessProbe:
  exec:
    command: [
      "source /healthcheck/utilities.sh && isDaemonSynced && isArchiveSynced"
    ]
{{- include "healthcheck.common.settings" . | indent 2 }}
{{- end }}

{{/*
ALL archive-node healthchecks  - TODO: readd startupProbes once GKE clusters have been updated to 1.16
*/}}
{{- define "healthcheck.archive.allChecks" }}
{{- include "healthcheck.archive.livenessCheck" . }}
{{- include "healthcheck.archive.readinessCheck" . }}
{{- end }}
