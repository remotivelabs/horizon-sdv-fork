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
Helm helpers for remotive-instance-template.
*/ -}}

{{- define "remotive-instance-template.workflowNamespace" -}}
{{- coalesce .Values.namespace (printf "%s%s" (.Values.namespacePrefix | default "") "workflows") -}}
{{- end -}}

{{- define "remotive-instance-template.workflowServiceAccountName" -}}
{{- if .Values.spec.useElevatedWorkflowIam -}}
workflow-executor-elevated
{{- else -}}
{{- .Values.spec.serviceAccountName | default "workflow-executor" -}}
{{- end -}}
{{- end -}}

{{- define "remotive-instance-template.scmAuthMethod" -}}
{{- $scm := .Values.scm | default dict -}}
{{- coalesce .Values.git.authMethod $scm.authMethod "" -}}
{{- end -}}

{{- define "remotive-instance-template.cloudEnvFrom" -}}
{{- if .Values.cloudEnvConfigMapName }}
envFrom:
  - configMapRef:
      name: {{ .Values.cloudEnvConfigMapName | quote }}
{{- end }}
{{- end -}}

{{- define "remotive-instance-template.builderImage" -}}
{{- printf "%s-docker.pkg.dev/%s/%s:%s" .Values.spec.cloudRegion .Values.spec.cloudProject .Values.spec.dockerArtifactPathName .Values.spec.builderImageTag -}}
{{- end -}}

{{- define "remotive-instance-template.gitArtifactCredsContent" -}}
{{- $auth := include "remotive-instance-template.scmAuthMethod" . | trim -}}
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

{{- define "remotive-instance-template.pipelineRepoGitArtifact" -}}
- name: pipeline-repo
  path: /workspace
  git:
    repo: {{ .Values.spec.pipelineRepoUrl | quote }}
    revision: {{ .Values.spec.pipelineRepoRevision | quote }}
{{- include "remotive-instance-template.gitArtifactCredsContent" . | nindent 4 }}
{{- end -}}

{{/*
Sensor skeleton parameters (all empty; defaults come from the WorkflowTemplate).
*/}}
{{- define "remotive-instance-template.sensorWebhookParameters" -}}
{{- range .Values.webhookWorkflowParameters }}
                    - name: {{ .name | quote }}
                      value: ""
{{- end }}
{{- end -}}

{{/*
Sensor trigger mappings: body.<bodyKey> -> spec.arguments.parameters.#(name=="<name>").value
*/}}
{{- define "remotive-instance-template.sensorWebhookParameterMappings" -}}
{{- range .Values.webhookWorkflowParameters }}
            - src:
                dependencyName: webhook-dep
                dataKey: body.{{ .bodyKey }}
              dest: spec.arguments.parameters.#(name=="{{ .name }}").value
{{- end }}
{{- end -}}
