// Copyright (c) 2026 Accenture, All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package controller

// PrefixedModuleExpectedManagedApplicationCount is the parent mod-* plus {prefix}{module} child Application count.
const PrefixedModuleExpectedManagedApplicationCount = 2

// remotiveKCCNamespaceSuffix is the module-owned namespace (after namespacePrefix) that holds remotive-topology's
// KCC ComputeInstanceTemplate CRs. It must match gitops/modules/remotive-topology/templates/namespace.yaml and the
// default of the remotive_instance_template chart's kccNamespace helper.
const remotiveKCCNamespaceSuffix = "remotive-kcc"

// ModuleUsesPrefixedChildApplication reports modules that use a mod-* parent and a prefixed child Argo CD Application.
// workloads-android, workloads-common and remotive-topology share the same child Application teardown shape.
// KCC ComputeInstanceTemplate cleanup runs for the modules known to moduleComputeInstanceTemplateNamespace;
// ConfigConnectorContext cleanup runs only for workloads-android.
func ModuleUsesPrefixedChildApplication(moduleName string) bool {
	switch moduleName {
	case "workloads-android", "workloads-common", "remotive-topology":
		return true
	default:
		return false
	}
}

// moduleComputeInstanceTemplateNamespace returns the namespace that holds a module's KCC ComputeInstanceTemplate
// CRs, or ok=false for modules without KCC instance templates. Every CR in the returned namespace is owned by that
// module and is removed on disable, so the two modules must never share a namespace: workloads-android publishes
// cf-it-* CRs into the platform {prefix}workflows namespace; remotive-topology publishes remotive-it-* CRs into
// {prefix}remotive-kcc, created and pruned by the mod-remotive-topology parent chart.
// moduleConfig may be empty; NamespacePrefixFromModuleConfig then uses MODULE_CONFIG from the environment.
func moduleComputeInstanceTemplateNamespace(moduleConfig, moduleName string) (ns string, ok bool) {
	prefix := NamespacePrefixFromModuleConfig(moduleConfig)
	switch moduleName {
	case "workloads-android":
		return prefix + "workflows", true
	case "remotive-topology":
		return prefix + remotiveKCCNamespaceSuffix, true
	default:
		return "", false
	}
}
