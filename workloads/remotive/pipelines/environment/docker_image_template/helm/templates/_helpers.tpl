{{- /*
Copyright (c) 2026 RemotiveLabs, All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Description:
Helm template helpers for remotive-builder-image (workflow namespace and service account).
*/ -}}

{{/*
Workflow namespace: explicit .Values.namespace, or namespacePrefix + "workflows".
*/}}
{{- define "remotive-builder-image.workflowNamespace" -}}
{{- coalesce .Values.namespace (printf "%s%s" (.Values.namespacePrefix | default "") "workflows") -}}
{{- end -}}

{{/*
Workflow pod service account: elevated when useElevatedWorkflowIam, else spec.serviceAccountName.
*/}}
{{- define "remotive-builder-image.workflowServiceAccountName" -}}
{{- if .Values.spec.useElevatedWorkflowIam -}}
workflow-executor-elevated
{{- else -}}
{{- .Values.spec.serviceAccountName | default "workflow-executor" -}}
{{- end -}}
{{- end -}}

{{/*
SCM auth: default values and GitOps set .Values.git.authMethod; .Values.scm.authMethod accepted for compatibility.
*/}}
{{- define "remotive-builder-image.scmAuthMethod" -}}
{{- $scm := .Values.scm | default dict -}}
{{- coalesce .Values.git.authMethod $scm.authMethod "" -}}
{{- end -}}

{{/*
Argo git artifact HTTPS credentials (same semantics as aaos-builder gitArtifactCredsContent).
*/}}
{{- define "remotive-builder-image.gitArtifactCredsContent" -}}
{{- $auth := include "remotive-builder-image.scmAuthMethod" . | trim -}}
{{- if and (or (eq $auth "app") (eq $auth "userpass")) (not (or .Values.localRepoHostPath .Values.localRepoPvcName)) }}
usernameSecret:
  name: "{{ "{{" }}workflow.uid{{ "}}" }}-pipeline-git-creds"
  key: username
passwordSecret:
  name: "{{ "{{" }}workflow.uid{{ "}}" }}-pipeline-git-creds"
  key: password
{{- else if .Values.spec.pipelineRepoSecret }}
usernameSecret:
  name: {{ .Values.spec.pipelineRepoSecret | quote }}
  key: username
passwordSecret:
  name: {{ .Values.spec.pipelineRepoSecret | quote }}
  key: password
{{- end }}
{{- end -}}
