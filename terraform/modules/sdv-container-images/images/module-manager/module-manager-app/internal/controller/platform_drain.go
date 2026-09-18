// Copyright (c) 2024-2026 Accenture, All Rights Reserved.
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

import (
	"context"
	"fmt"
	"os"
	"sort"

	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PlatformDrainFinalizer blocks root horizon-sdv Application deletion until module apps are drained.
const PlatformDrainFinalizer = "horizon-sdv.io/module-manager-platform-drain"

// APIGroupLister is the narrow interface from k8s.io/client-go/discovery used by the KCC
// finalizer stripper. Using a narrow interface here keeps the production code testable
// without a full discovery.DiscoveryInterface mock.
type APIGroupLister interface {
	ServerGroupsAndResources() ([]*metav1.APIGroup, []*metav1.APIResourceList, error)
}

// ModuleManagerManagedLabelKey identifies Applications created by Module Manager for teardown.
const ModuleManagerManagedLabelKey = "horizon-sdv.io/module-manager-managed"

// ModuleManagerAppRoleLabelKey distinguishes parent Applications (single spec.source, MODULE_CONFIG helm sync)
// from child multi-source Applications rendered by module charts (spec.sources only).
const ModuleManagerAppRoleLabelKey = "horizon-sdv.io/app-role"

// ModuleManagerAppRoleParent is the label value for module parent Applications created by the enable API.
const ModuleManagerAppRoleParent = "parent"

// PlatformDrainer performs ordered disable of all modules (root Application finalizer path).
type PlatformDrainer struct {
	Client          client.Client
	APIReader       client.Reader
	DiscoveryClient APIGroupLister
	StateStore      StateStoreInterface
	CatalogStore    CatalogStoreInterface
	Namespace       string
	ArgoCDNamespace string
	ArgoCDProject   string
}

// DrainAllEnabledModules deletes module Applications in safe order (dependents before dependencies),
// then strips KCC finalizers in destination namespaces so that KCC-managed resources do not block
// namespace termination during platform destroy.
func (p *PlatformDrainer) DrainAllEnabledModules(ctx context.Context) error {
	for {
		state, err := p.StateStore.Get(ctx)
		if err != nil {
			return err
		}
		enabledSet := make(map[string]bool)
		for _, id := range state.EnabledModules {
			enabledSet[id] = true
		}
		if len(state.EnabledModules) == 0 {
			break
		}
		idToName := make(map[string]string)
		for n, id := range state.ModuleIDs {
			idToName[id] = n
		}
		var candidates []string
		for _, id := range state.EnabledModules {
			if n := idToName[id]; n != "" {
				candidates = append(candidates, n)
			}
		}
		sort.Strings(candidates)

		var next string
		for _, name := range candidates {
			if p.allHardDepsDisabledOrAbsent(ctx, name, enabledSet, state) {
				next = name
				break
			}
		}
		if next == "" {
			return fmt.Errorf("platform drain: no module eligible to disable (cycle or state mismatch)")
		}
		if err := p.disableOne(ctx, next); err != nil {
			return err
		}
	}

	// After all parent Applications have been deleted, proactively strip KCC finalizers in
	// module destination namespaces so that KCC-managed resources (e.g. PubSubTopic) do not
	// block namespace termination when KCC has lost GCP authentication.
	nss := p.ManagedDestinationNamespaces(ctx, p.ArgoCDNamespace)
	// Module-owned KCC namespaces are not Application destinations (workflows publish the CRs there), so they
	// are not discovered above; add remotive-topology's namespace explicitly (absent namespaces list nothing).
	nss = appendNamespaceOnce(nss, NamespacePrefixFromModuleConfig(os.Getenv("MODULE_CONFIG"))+remotiveKCCNamespaceSuffix)
	return p.StripKCCFinalizersInNamespaces(ctx, nss)
}

func (p *PlatformDrainer) allHardDepsDisabledOrAbsent(ctx context.Context, moduleName string, enabledSet map[string]bool, state *State) bool {
	hard := p.hardDepsForModule(ctx, moduleName)
	for _, dep := range hard {
		depID := state.ModuleIDs[dep]
		if depID != "" && enabledSet[depID] {
			return false
		}
	}
	return true
}

func (p *PlatformDrainer) hardDepsForModule(ctx context.Context, moduleName string) []string {
	entries, _ := p.CatalogStore.List(ctx)
	for i := range entries {
		if entries[i].Name == moduleName {
			return append([]string(nil), entries[i].HardDependencies...)
		}
	}
	return nil
}

// disableOne removes one enabled module during platform drain. Unlike PerformModuleDisable (REST/Portal
// single-module disable), it deletes the parent mod-* Application before updating ModuleManagerState—ordering
// is optimized for whole-platform teardown, not per-module Portal UX.
func (p *PlatformDrainer) disableOne(ctx context.Context, moduleName string) error {
	state, err := p.StateStore.Get(ctx)
	if err != nil {
		return err
	}
	modID := state.ModuleIDs[moduleName]
	enabledSet := make(map[string]bool)
	for _, id := range state.EnabledModules {
		enabledSet[id] = true
	}
	if modID == "" || !enabledSet[modID] {
		return nil
	}

	if err := TeardownPrefixedModuleChildApplication(ctx, p.Client, p.ArgoCDNamespace, os.Getenv("MODULE_CONFIG"), moduleName); err != nil {
		return err
	}

	appName := ApplicationName(moduleName)
	app := &unstructured.Unstructured{}
	app.SetGroupVersionKind(schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "Application"})
	app.SetNamespace(p.ArgoCDNamespace)
	app.SetName(appName)
	if err := p.Client.Delete(ctx, app); err != nil && !errors.IsNotFound(err) {
		// Teardown may have set skip-reconcile on mod-*; clear so the cluster is not left with a frozen parent
		// if delete fails (platform drain does not update state until after delete).
		clearParentSkipReconcileIfPrefixedModule(ctx, p.Client, p.ArgoCDNamespace, moduleName)
		return err
	}
	var newEnabled []string
	for _, id := range state.EnabledModules {
		if id != modID {
			newEnabled = append(newEnabled, id)
		}
	}
	state.EnabledModules = newEnabled
	if err := p.StateStore.Update(ctx, state); err != nil {
		return err
	}
	_ = ResyncSoftFeaturesForParentsOfSoftDep(ctx, p.APIReader, p.Client, p.ArgoCDNamespace, p.Namespace, p.StateStore, p.CatalogStore, moduleName)
	return nil
}

// ManagedModuleApplicationsRemaining returns true if any labeled module Application still exists.
func (p *PlatformDrainer) ManagedModuleApplicationsRemaining(ctx context.Context, argoCDNamespace string) (bool, error) {
	ul := &unstructured.UnstructuredList{}
	ul.SetGroupVersionKind(schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "ApplicationList"})
	if err := p.APIReader.List(ctx, ul,
		client.InNamespace(argoCDNamespace),
		client.MatchingLabels{ModuleManagerManagedLabelKey: "true"}); err != nil {
		return false, err
	}
	return len(ul.Items) > 0, nil
}

// ManagedDestinationNamespaces returns the unique set of spec.destination.namespace values
// across all module-manager-managed Applications in argoCDNamespace. Used to scope the KCC
// finalizer stripper to only namespaces owned by module-manager.
func (p *PlatformDrainer) ManagedDestinationNamespaces(ctx context.Context, argoCDNamespace string) []string {
	ul := &unstructured.UnstructuredList{}
	ul.SetGroupVersionKind(schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "ApplicationList"})
	if err := p.APIReader.List(ctx, ul,
		client.InNamespace(argoCDNamespace),
		client.MatchingLabels{ModuleManagerManagedLabelKey: "true"}); err != nil {
		return nil
	}
	seen := map[string]struct{}{}
	for i := range ul.Items {
		ns, _, _ := unstructured.NestedString(ul.Items[i].Object, "spec", "destination", "namespace")
		if ns != "" {
			seen[ns] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for ns := range seen {
		out = append(out, ns)
	}
	return out
}

// appendNamespaceOnce appends ns unless it is empty or already present.
func appendNamespaceOnce(nss []string, ns string) []string {
	if ns == "" {
		return nss
	}
	for _, existing := range nss {
		if existing == ns {
			return nss
		}
	}
	return append(nss, ns)
}

// RemovePlatformDrainFinalizer removes only Module Manager's finalizer from the root Application.
func (p *PlatformDrainer) RemovePlatformDrainFinalizer(ctx context.Context, ns, name string) error {
	app := &unstructured.Unstructured{}
	app.SetGroupVersionKind(schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "Application"})
	key := client.ObjectKey{Namespace: ns, Name: name}
	if err := p.Client.Get(ctx, key, app); err != nil {
		return client.IgnoreNotFound(err)
	}
	finalizers := app.GetFinalizers()
	var kept []string
	for _, f := range finalizers {
		if f != PlatformDrainFinalizer {
			kept = append(kept, f)
		}
	}
	if len(kept) == len(finalizers) {
		return nil
	}
	app.SetFinalizers(kept)
	return p.Client.Update(ctx, app)
}
