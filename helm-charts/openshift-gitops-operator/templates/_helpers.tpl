{{/*
Expand the name of the chart.
*/}}
{{- define "openshift-gitops-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "openshift-gitops-operator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openshift-gitops-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openshift-gitops-operator.labels" -}}
helm.sh/chart: {{ include "openshift-gitops-operator.chart" . }}
{{ include "openshift-gitops-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openshift-gitops-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openshift-gitops-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "openshift-gitops-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name }}
{{- else }}
{{- include "openshift-gitops-operator.fullname" . }}
{{- end }}
{{- end }}

{{/*
Build an image reference from an image config dict.
Supports both tag (:v1.0) and digest (@sha256:...) references.
Usage: {{ include "openshift-gitops-operator.image" .Values.image.manager }}
*/}}
{{- define "openshift-gitops-operator.image" -}}
{{- $sep := ":" }}
{{- if hasPrefix "sha256:" .tag }}
{{- $sep = "@" }}
{{- end }}
{{- if .registry }}
{{- printf "%s/%s%s%s" .registry .repository $sep .tag }}
{{- else }}
{{- printf "%s%s%s" .repository $sep .tag }}
{{- end }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "openshift-gitops-operator.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
