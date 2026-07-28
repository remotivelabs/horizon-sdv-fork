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
Helm helpers for remotive-launcher (RemotiveTopology on ephemeral GCE).
*/ -}}

{{- define "remotive-launcher.workflowNamespace" -}}
{{- coalesce .Values.namespace (printf "%s%s" (.Values.namespacePrefix | default "") "workflows") -}}
{{- end -}}

{{- define "remotive-launcher.workflowServiceAccountName" -}}
{{- if .Values.spec.useElevatedWorkflowIam -}}
workflow-executor-elevated
{{- else -}}
{{- .Values.spec.serviceAccountName | default "workflow-executor" -}}
{{- end -}}
{{- end -}}

{{- define "remotive-launcher.scmAuthMethod" -}}
{{- $scm := .Values.scm | default dict -}}
{{- coalesce .Values.git.authMethod $scm.authMethod "" -}}
{{- end -}}

{{- define "remotive-launcher.cloudEnvFrom" -}}
{{- if .Values.cloudEnvConfigMapName }}
envFrom:
  - configMapRef:
      name: {{ .Values.cloudEnvConfigMapName | quote }}
{{- end }}
{{- end -}}

{{- define "remotive-launcher.builderImage" -}}
{{- printf "%s-docker.pkg.dev/%s/%s:%s" .Values.spec.cloudRegion .Values.spec.cloudProject .Values.spec.dockerArtifactPathName .Values.spec.builderImageTag -}}
{{- end -}}

{{- define "remotive-launcher.gitArtifactCredsContent" -}}
{{- $auth := include "remotive-launcher.scmAuthMethod" . | trim -}}
{{- if or (eq $auth "app") (eq $auth "userpass") }}
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

{{- define "remotive-launcher.pipelineRepoGitArtifact" -}}
- name: pipeline-repo
  path: /workspace
  git:
    repo: {{ .Values.spec.pipelineRepoUrl | quote }}
    revision: {{ .Values.spec.pipelineRepoRevision | quote }}
{{- include "remotive-launcher.gitArtifactCredsContent" . | nindent 4 }}
{{- end -}}

{{/*
RemotiveCloud auth env vars from the workflows-namespace Secret (optional so pods
start without it; the guest fails fast with a clear message when values are missing).
*/}}
{{- define "remotive-launcher.remotiveCloudEnv" -}}
{{- if .Values.spec.remotiveCloudSecretName }}
- name: REMOTIVE_CLOUD_AUTH_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.spec.remotiveCloudSecretName | quote }}
      key: {{ .Values.spec.remotiveCloudTokenKey | default "token" | quote }}
      optional: true
- name: REMOTIVE_CLOUD_ORGANIZATION
  valueFrom:
    secretKeyRef:
      name: {{ .Values.spec.remotiveCloudSecretName | quote }}
      key: {{ .Values.spec.remotiveCloudOrganizationKey | default "organization" | quote }}
      optional: true
{{- end }}
{{- end -}}

{{- define "remotive-launcher.mtkConnectEnv" -}}
{{- if .Values.spec.mtkConnectSecretName }}
- name: MTK_CONNECT_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.spec.mtkConnectSecretName | quote }}
      key: {{ .Values.spec.mtkConnectUsernameKey | default "username" | quote }}
      optional: true
- name: MTK_CONNECT_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.spec.mtkConnectSecretName | quote }}
      key: {{ .Values.spec.mtkConnectPasswordKey | default "password" | quote }}
      optional: true
{{- end }}
{{- end -}}

{{- define "remotive-launcher.sensorWebhookParameters" -}}
{{- range .Values.webhookWorkflowParameters }}
                    - name: {{ .name | quote }}
                      value: ""
{{- end }}
{{- end -}}

{{- define "remotive-launcher.sensorWebhookParameterMappings" -}}
{{- range .Values.webhookWorkflowParameters }}
            - src:
                dependencyName: webhook-dep
                dataKey: body.{{ .bodyKey }}
              dest: spec.arguments.parameters.#(name=="{{ .name }}").value
{{- end }}
{{- end -}}
