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
Build task definitions for remotive-builder-image.
Dependencies: uses shared ClusterWorkflowTemplate common-docker-image-build (module workloads-common).
*/ -}}

{{- define "remotive-builder-image.template.build" -}}
{{- $useLocalRepo := or .Values.localRepoHostPath .Values.localRepoPvcName -}}
{{- $auth := include "remotive-builder-image.scmAuthMethod" . | trim -}}
{{- $umbrellaCreds := and (not $useLocalRepo) (or (eq $auth "app") (eq $auth "userpass")) -}}
- name: build
  dag:
    tasks:
{{- if $umbrellaCreds }}
      - name: prepare-pipeline-git-creds
        templateRef:
          name: prepare-pipeline-git-creds
          template: prepare-pipeline-git-creds
          clusterScope: true
        arguments:
          parameters:
            - name: scmAuthMethod
              value: {{ include "remotive-builder-image.scmAuthMethod" . | trim | quote }}
            - name: pipelineStaticGitSecretName
              value: {{ .Values.spec.pipelineRepoSecret | default "workflow-pipeline-git-creds" | quote }}
            - name: horizonSubmittedFrom
              value: '{{ "{{" }}workflow.parameters.horizonSubmittedFrom{{ "}}" }}'
{{- end }}
      - name: build-image
        templateRef:
          name: {{ .Values.clusterWorkflowTemplateName | quote }}
          template: build
          clusterScope: true
{{- if $umbrellaCreds }}
        depends: prepare-pipeline-git-creds.Succeeded
{{- end }}
        arguments:
{{- if not $useLocalRepo }}
          artifacts:
            - name: source
              path: /workspace
              git:
                repo: {{ .Values.spec.pipelineRepoUrl | quote }}
                revision: {{ .Values.spec.pipelineRepoRevision | quote }}
{{- include "remotive-builder-image.gitArtifactCredsContent" . | nindent 16 }}
{{- end }}
          parameters:
            - name: horizonSubmittedFrom
              value: '{{ "{{" }}workflow.parameters.horizonSubmittedFrom{{ "}}" }}'
            - name: cloudProject
              value: {{ .Values.spec.cloudProject | quote }}
            - name: cloudRegion
              value: {{ .Values.spec.cloudRegion | quote }}
            - name: dockerArtifactPathName
              value: "{{ "{{" }}workflow.parameters.dockerArtifactPathName{{ "}}" }}"
            - name: imageTag
              value: "{{ "{{" }}workflow.parameters.imageTag{{ "}}" }}"
            - name: dryRun
              value: "{{ "{{" }}workflow.parameters.dryRun{{ "}}" }}"
            - name: dockerfileDir
              value: {{ .Values.spec.dockerfileDir | quote }}
            - name: buildArgs
              value: |
                LINUX_DISTRIBUTION={{ "{{" }}workflow.parameters.linuxDistribution{{ "}}" }}
                GCLOUD_CLI_VERSION={{ "{{" }}workflow.parameters.gcloudCliVersion{{ "}}" }}
                KUBECTL_VERSION={{ "{{" }}workflow.parameters.kubectlVersion{{ "}}" }}
                PACKER_VERSION={{ "{{" }}workflow.parameters.packerVersion{{ "}}" }}
            - name: platform
              value: linux/amd64
{{- end }}
