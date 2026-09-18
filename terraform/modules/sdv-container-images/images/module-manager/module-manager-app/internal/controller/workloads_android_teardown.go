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

import (
	"context"
	"fmt"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// prefixedModuleChildApplicationName matches gitops module charts that render a child Application named
// {{ .Values.config.namespacePrefix }}<module-with-hyphens> (e.g. workloads-android, workloads-common).
func prefixedModuleChildApplicationName(namespacePrefix, moduleName string) string {
	return namespacePrefix + strings.ReplaceAll(moduleName, "_", "-")
}

const (
	moduleChildApplicationPollInterval = 5 * time.Second
	// How long to wait for the prefixed child Argo CD Application CR to disappear after Delete, before
	// stripping Application finalizers. Argo prune (especially multi-source workloads-android) often
	// exceeds 2m; 10m reduces premature finalizer stripping. KCC CIT/CCC waits are separate (up to 15m each).
	moduleChildApplicationDeleteWait = 10 * time.Minute
	// After removing Argo CD–owned finalizers, allow this long for the API server to drop the Application CR.
	moduleChildPostArgoFinalizerWait = 60 * time.Second

	cuttlefishComputeInstanceTemplatePollInterval    = 10 * time.Second
	cuttlefishComputeInstanceTemplateWaitAfterDelete = 15 * time.Minute

	// Shared poll budget for workflows-namespace ConfigConnectorContext during enable (wait until
	// not terminating) and disable (delete if live, then wait until absent).
	configConnectorContextPollInterval = 10 * time.Second
	configConnectorContextMaxWait      = 15 * time.Minute
	// When CCC is terminating, the GKE addon may keep status.errors claiming ComputeInstanceTemplate(s) remain
	// while the Kubernetes API lists zero CRs (stale controller state). After this many consecutive polls
	// (configConnectorContextPollInterval) with zero CITs, strip CCC metadata.finalizers if status.errors
	// match the known pattern — same break-glass as manual kubectl, automated for Portal disable.
	cccStaleCitZeroCountPollsBeforeFinalizerStrip = 3

	argoApplicationWriteMaxAttempts = 5

	argoCDSkipReconcileAnnotationKey = "argocd.argoproj.io/skip-reconcile"
)

var argoCDApplicationGVK = schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "Application"}

var configConnectorContextGVKs = []schema.GroupVersionKind{
	{Group: "core.cnrm.cloud.google.com", Version: "v1beta1", Kind: "ConfigConnectorContext"},
	{Group: "core.cnrm.cloud.google.com", Version: "v1alpha1", Kind: "ConfigConnectorContext"},
}

const configConnectorContextCRName = "configconnectorcontext.core.cnrm.cloud.google.com"

// cuttlefishComputeInstanceTemplatesRemaining counts every CNRM ComputeInstanceTemplate in the list. Module KCC
// namespaces are single-owner (see moduleComputeInstanceTemplateNamespace), so every CR counts; for
// workloads-android, ConfigConnectorContext finalization is blocked while any remain in the namespace.
func cuttlefishComputeInstanceTemplatesRemaining(ul *unstructured.UnstructuredList) int {
	if ul == nil {
		return 0
	}
	return len(ul.Items)
}

func listComputeInstanceTemplates(ctx context.Context, c client.Client, ns string, listOpts ...client.ListOption) (*unstructured.UnstructuredList, error) {
	for _, ver := range []string{"v1beta1", "v1alpha1"} {
		ul := &unstructured.UnstructuredList{}
		ul.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "compute.cnrm.cloud.google.com",
			Version: ver,
			Kind:    "ComputeInstanceTemplateList",
		})
		err := c.List(ctx, ul, append([]client.ListOption{client.InNamespace(ns)}, listOpts...)...)
		if err == nil {
			return ul, nil
		}
		if meta.IsNoMatchError(err) {
			continue
		}
		if errors.IsNotFound(err) {
			return &unstructured.UnstructuredList{}, nil
		}
		return nil, err
	}
	return &unstructured.UnstructuredList{}, nil
}

func waitForCuttlefishComputeInstanceTemplatesAbsent(ctx context.Context, c client.Client, moduleConfig, moduleName string) error {
	ns, ok := moduleComputeInstanceTemplateNamespace(moduleConfig, moduleName)
	if !ok {
		return nil
	}
	logger := log.FromContext(ctx).WithValues("module", moduleName)
	deadline := time.Now().Add(cuttlefishComputeInstanceTemplateWaitAfterDelete)
	var lastRemaining int
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		ul, err := listComputeInstanceTemplates(ctx, c, ns)
		if err != nil {
			return fmt.Errorf("list ComputeInstanceTemplate while waiting in namespace %q: %w", ns, err)
		}
		rem := cuttlefishComputeInstanceTemplatesRemaining(ul)
		if rem == 0 {
			logger.Info("ComputeInstanceTemplate CRs cleared from namespace", "namespace", ns)
			return nil
		}
		if rem != lastRemaining {
			logger.Info("waiting for ComputeInstanceTemplate CRs to leave namespace (CNRM finalizers / GCP)",
				"namespace", ns, "remaining", rem)
			lastRemaining = rem
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(cuttlefishComputeInstanceTemplatePollInterval):
		}
	}
	return fmt.Errorf("timed out after %s waiting for ComputeInstanceTemplate CRs to be removed from namespace %q (last count %d)",
		cuttlefishComputeInstanceTemplateWaitAfterDelete, ns, lastRemaining)
}

// terminateArgoCDApplicationOperationIfAny clears spec.operation on an Argo CD Application (UI "terminate sync"
// equivalent) so delete/finalizers are not racing an in-flight sync.
func terminateArgoCDApplicationOperationIfAny(ctx context.Context, c client.Client, argocdNamespace, appName string) error {
	logger := log.FromContext(ctx).WithValues("application", appName, "namespace", argocdNamespace)
	key := types.NamespacedName{Namespace: argocdNamespace, Name: appName}

	for attempt := 0; attempt < argoApplicationWriteMaxAttempts; attempt++ {
		app := &unstructured.Unstructured{}
		app.SetGroupVersionKind(argoCDApplicationGVK)
		if err := c.Get(ctx, key, app); err != nil {
			return client.IgnoreNotFound(err)
		}
		op, found, err := unstructured.NestedMap(app.Object, "spec", "operation")
		if err != nil {
			return fmt.Errorf("read spec.operation: %w", err)
		}
		if !found || op == nil || len(op) == 0 {
			return nil
		}
		patch := []byte(`{"spec":{"operation":null}}`)
		if err := c.Patch(ctx, app, client.RawPatch(types.MergePatchType, patch)); err != nil {
			if errors.IsConflict(err) {
				logger.V(1).Info("conflict terminating Application operation; retrying", "attempt", attempt+1)
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(moduleChildApplicationPollInterval):
				}
				continue
			}
			return fmt.Errorf("terminate Application operation (clear spec.operation): %w", err)
		}
		logger.Info("terminated in-flight Argo CD Application operation")
		return nil
	}
	return fmt.Errorf("give up terminating Application operation for %s/%s after %d conflict retries",
		argocdNamespace, appName, argoApplicationWriteMaxAttempts)
}

// disableArgoCDApplicationAutomatedSyncIfAny removes spec.syncPolicy.automated so Argo does not start repair
// syncs while the Application or its managed resources are being torn down.
func disableArgoCDApplicationAutomatedSyncIfAny(ctx context.Context, c client.Client, argocdNamespace, appName string) error {
	logger := log.FromContext(ctx).WithValues("application", appName, "namespace", argocdNamespace)
	key := types.NamespacedName{Namespace: argocdNamespace, Name: appName}

	for attempt := 0; attempt < argoApplicationWriteMaxAttempts; attempt++ {
		app := &unstructured.Unstructured{}
		app.SetGroupVersionKind(argoCDApplicationGVK)
		if err := c.Get(ctx, key, app); err != nil {
			return client.IgnoreNotFound(err)
		}
		auto, found, err := unstructured.NestedMap(app.Object, "spec", "syncPolicy", "automated")
		if err != nil {
			return fmt.Errorf("read spec.syncPolicy.automated: %w", err)
		}
		if !found || auto == nil {
			return nil
		}
		patch := []byte(`{"spec":{"syncPolicy":{"automated":null}}}`)
		if err := c.Patch(ctx, app, client.RawPatch(types.MergePatchType, patch)); err != nil {
			if errors.IsConflict(err) {
				logger.V(1).Info("conflict disabling Application automated sync; retrying", "attempt", attempt+1)
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(moduleChildApplicationPollInterval):
				}
				continue
			}
			return fmt.Errorf("disable Application automated sync (clear spec.syncPolicy.automated): %w", err)
		}
		logger.Info("disabled Argo CD Application automated sync for teardown")
		return nil
	}
	return fmt.Errorf("give up disabling Application automated sync for %s/%s after %d conflict retries",
		argocdNamespace, appName, argoApplicationWriteMaxAttempts)
}

// setArgoCDApplicationSkipReconcile sets or clears metadata.annotations[argocd.argoproj.io/skip-reconcile] on an
// Argo CD Application so the controller stops reconciling desired state from Git (Argo CD 2.7+). Clearing
// automated sync alone does not prevent the app controller from re-creating pruned child Applications.
func setArgoCDApplicationSkipReconcile(ctx context.Context, c client.Client, argocdNamespace, appName string, skip bool) error {
	logger := log.FromContext(ctx).WithValues("application", appName, "namespace", argocdNamespace)
	key := types.NamespacedName{Namespace: argocdNamespace, Name: appName}

	for attempt := 0; attempt < argoApplicationWriteMaxAttempts; attempt++ {
		app := &unstructured.Unstructured{}
		app.SetGroupVersionKind(argoCDApplicationGVK)
		if err := c.Get(ctx, key, app); err != nil {
			return client.IgnoreNotFound(err)
		}
		cur, found, err := unstructured.NestedString(app.Object, "metadata", "annotations", argoCDSkipReconcileAnnotationKey)
		if err != nil {
			return fmt.Errorf("read metadata.annotations[%s]: %w", argoCDSkipReconcileAnnotationKey, err)
		}
		if skip {
			if found && cur == "true" {
				return nil
			}
		} else {
			if !found {
				return nil
			}
		}

		var patch []byte
		if skip {
			patch = []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:"true"}}}`, argoCDSkipReconcileAnnotationKey))
		} else {
			patch = []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:null}}}`, argoCDSkipReconcileAnnotationKey))
		}
		if err := c.Patch(ctx, app, client.RawPatch(types.MergePatchType, patch)); err != nil {
			if errors.IsConflict(err) {
				logger.V(1).Info("conflict patching Application skip-reconcile; retrying", "attempt", attempt+1)
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(moduleChildApplicationPollInterval):
				}
				continue
			}
			return fmt.Errorf("patch Application skip-reconcile=%v: %w", skip, err)
		}
		logger.Info("patched Argo CD Application skip-reconcile", "skip", skip)
		return nil
	}
	return fmt.Errorf("give up patching Application skip-reconcile for %s/%s after %d conflict retries",
		argocdNamespace, appName, argoApplicationWriteMaxAttempts)
}

// deletePrefixedChildApplicationIfPresent removes the prefixed child Application when it still exists.
// After clearParentSkipReconcile, the mod-* parent can reconcile from Git and recreate workloads-android
// before the parent CR is deleted; a second delete here avoids enabled=false with a healthy child Application.
// Full CCC/CIT teardown is not repeated — TeardownPrefixedModuleChildApplication already ran.
func deletePrefixedChildApplicationIfPresent(ctx context.Context, c client.Client, argocdNamespace, moduleConfig, moduleName string) error {
	if !ModuleUsesPrefixedChildApplication(moduleName) {
		return nil
	}
	logger := log.FromContext(ctx)
	prefix := NamespacePrefixFromModuleConfig(moduleConfig)
	childName := prefixedModuleChildApplicationName(prefix, moduleName)
	child := &unstructured.Unstructured{}
	child.SetGroupVersionKind(argoCDApplicationGVK)
	child.SetNamespace(argocdNamespace)
	child.SetName(childName)
	if err := c.Get(ctx, client.ObjectKeyFromObject(child), child); err != nil {
		if errors.IsNotFound(err) {
			return nil
		}
		return err
	}
	logger.Info("deleting prefixed-module child Application recreated before parent delete",
		"module", moduleName, "application", childName, "namespace", argocdNamespace)
	if err := c.Delete(ctx, child); err != nil && !errors.IsNotFound(err) {
		return fmt.Errorf("delete recreated child Application %q: %w", childName, err)
	}
	return nil
}

// clearParentSkipReconcileIfPrefixedModule clears skip-reconcile on the mod-* parent for workloads-android
// and workloads-common. Call after successful prefixed child teardown so Argo can prune managed resources
// before the parent Application delete finalizes; also from error paths when disable cannot complete.
func clearParentSkipReconcileIfPrefixedModule(ctx context.Context, c client.Client, argocdNamespace, moduleName string) {
	if !ModuleUsesPrefixedChildApplication(moduleName) {
		return
	}
	parentName := ApplicationName(moduleName)
	if err := setArgoCDApplicationSkipReconcile(ctx, c, argocdNamespace, parentName, false); err != nil {
		log.FromContext(ctx).Error(err, "clear skip-reconcile on parent Application (prefixed module)",
			"application", parentName, "namespace", argocdNamespace)
	}
}

// preparePrefixedModuleParentAndChildForDelete stops the mod-* parent from re-applying the child Application from Git
// while the child is torn down. It terminates the parent operation, sets skip-reconcile on the parent immediately
// (before touching the child), then clears parent and child automated sync and terminates the child operation.
// skip-reconcile must come before child-side patches: otherwise Argo can reconcile the parent in the gap after
// automated=null and recreate the child Application from Git (workloads-android timing).
func preparePrefixedModuleParentAndChildForDelete(ctx context.Context, c client.Client, argocdNamespace, moduleName, childName string) (err error) {
	parentName := ApplicationName(moduleName)
	skipPlaced := false
	defer func() {
		if !skipPlaced || err == nil {
			return
		}
		cleanupCtx := context.Background()
		if e := setArgoCDApplicationSkipReconcile(cleanupCtx, c, argocdNamespace, parentName, false); e != nil {
			log.FromContext(ctx).Error(e, "clear skip-reconcile on parent after preparePrefixedModuleParentAndChildForDelete failed",
				"application", parentName, "namespace", argocdNamespace)
		}
	}()

	if err = terminateArgoCDApplicationOperationIfAny(ctx, c, argocdNamespace, parentName); err != nil {
		return fmt.Errorf("terminate parent Application operation %q: %w", parentName, err)
	}
	if err = setArgoCDApplicationSkipReconcile(ctx, c, argocdNamespace, parentName, true); err != nil {
		return fmt.Errorf("set parent Application skip-reconcile %q: %w", parentName, err)
	}
	skipPlaced = true
	// Stable message prefix for grepping module-manager logs during workloads-android / workloads-common disable.
	log.FromContext(ctx).Info("prefixed_module_teardown: set argocd.argoproj.io/skip-reconcile on parent Application (Git reconcile paused)",
		"application", parentName, "namespace", argocdNamespace, "module", moduleName, "childApplication", childName)
	if err = disableArgoCDApplicationAutomatedSyncIfAny(ctx, c, argocdNamespace, parentName); err != nil {
		return fmt.Errorf("disable parent Application automated sync %q: %w", parentName, err)
	}
	if err = terminateArgoCDApplicationOperationIfAny(ctx, c, argocdNamespace, childName); err != nil {
		return fmt.Errorf("terminate child Application operation %q: %w", childName, err)
	}
	if err = disableArgoCDApplicationAutomatedSyncIfAny(ctx, c, argocdNamespace, childName); err != nil {
		return fmt.Errorf("disable child Application automated sync %q: %w", childName, err)
	}
	return nil
}

// ensureCuttlefishComputeInstanceTemplatesRemoved deletes every KCC ComputeInstanceTemplate CR in the module's
// KCC namespace (moduleComputeInstanceTemplateNamespace: {prefix}workflows for workloads-android,
// {prefix}remotive-kcc for remotive-topology) and polls until all CRs are gone from the API (including
// terminating objects). CNRM deletes the matching GCP instance templates.
// This is the authoritative cleanup on disable: Argo CD has no PreDelete hook type (the charts' historical
// "PreDelete" Jobs never ran), a chart PostDelete hook only runs after the child prune completes, and the child
// Application may be stuck until CCC finalizes. For workloads-android, issuing deletes as soon as the child
// Application delete is started avoids a CCC↔CIT deadlock (the Addon blocks CCC deletion while any CIT remains).
// Also used after the child CR is gone if finalizers were stripped manually.
func ensureCuttlefishComputeInstanceTemplatesRemoved(ctx context.Context, c client.Client, moduleConfig, moduleName string) error {
	ns, ok := moduleComputeInstanceTemplateNamespace(moduleConfig, moduleName)
	if !ok {
		return nil
	}
	logger := log.FromContext(ctx).WithValues("module", moduleName)

	ul, err := listComputeInstanceTemplates(ctx, c, ns)
	if err != nil {
		return fmt.Errorf("list ComputeInstanceTemplate in namespace %q: %w", ns, err)
	}
	var toDelete []unstructured.Unstructured
	for i := range ul.Items {
		item := ul.Items[i]
		if !item.GetDeletionTimestamp().IsZero() {
			continue
		}
		toDelete = append(toDelete, item)
	}
	if len(toDelete) > 0 {
		logger.Info("deleting ComputeInstanceTemplate CRs during module teardown (all in module KCC namespace)",
			"namespace", ns, "count", len(toDelete))
		for i := range toDelete {
			it := toDelete[i]
			if err := c.Delete(ctx, &it); err != nil && !errors.IsNotFound(err) {
				return fmt.Errorf("delete ComputeInstanceTemplate %s/%s: %w", ns, it.GetName(), err)
			}
		}
	}
	return waitForCuttlefishComputeInstanceTemplatesAbsent(ctx, c, moduleConfig, moduleName)
}

// WaitModuleKCCNamespaceNotTerminating blocks module enable while a module-owned KCC namespace is still
// Terminating from the previous disable (remotive-topology: {prefix}remotive-kcc is pruned with the mod-*
// parent chart, and namespace termination waits for CNRM to finalize any leftover ComputeInstanceTemplate).
// The parent Application syncs without retry, so re-creating the Namespace while it terminates would leave
// mod-* OutOfSync until a manual sync. workloads-android uses the platform workflows namespace (never pruned).
func WaitModuleKCCNamespaceNotTerminating(ctx context.Context, c client.Client, moduleConfig, moduleName string) error {
	if moduleName != "remotive-topology" {
		return nil
	}
	ns, ok := moduleComputeInstanceTemplateNamespace(moduleConfig, moduleName)
	if !ok {
		return nil
	}
	logger := log.FromContext(ctx).WithValues("module", moduleName, "namespace", ns)
	deadline := time.Now().Add(configConnectorContextMaxWait)
	logged := false
	for {
		nsObj := &unstructured.Unstructured{}
		nsObj.SetGroupVersionKind(schema.GroupVersionKind{Version: "v1", Kind: "Namespace"})
		err := c.Get(ctx, types.NamespacedName{Name: ns}, nsObj)
		if errors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("get module KCC namespace %q: %w", ns, err)
		}
		if nsObj.GetDeletionTimestamp().IsZero() {
			return nil
		}
		if !logged {
			logger.Info("module KCC namespace is still terminating from the previous disable; waiting before enable")
			logged = true
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("module KCC namespace %q is still terminating after %s (leftover CNRM ComputeInstanceTemplate finalizers?); retry enable later",
				ns, configConnectorContextMaxWait)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(configConnectorContextPollInterval):
		}
	}
}

// partitionArgoCDFinalizers splits finalizers into those owned by the argoproj.io API group (typical Argo CD
// Application finalizers such as resources-finalizer.argocd.argoproj.io) vs all others.
func partitionArgoCDFinalizers(finalizers []string) (kept, removed []string) {
	for _, f := range finalizers {
		if strings.Contains(f, "argoproj.io") {
			removed = append(removed, f)
			continue
		}
		kept = append(kept, f)
	}
	return kept, removed
}

// TeardownPrefixedModuleChildApplication deletes the multi-source child Application before removing mod-{module}.
// It first terminates the parent operation and sets skip-reconcile on mod-* (before child patches), clears
// spec.syncPolicy.automated on parent and child (and terminates the child operation), then deletes the child.
// Skip-reconcile must be applied before child-side disables: otherwise the parent controller can reconcile in the
// gap after automated=null and recreate the child from Git (especially workloads-android), which surfaces as
// mod-* Syncing vs {prefix}workloads-* Deleting.
// If the child CR remains after moduleChildApplicationDeleteWait, finalizers are cleared in two phases:
// Argo CD *.argoproj.io finalizers first, a short wait, then all remaining finalizers only as a last resort.
//
// For workloads-android and remotive-topology, this path removes pipeline-owned ComputeInstanceTemplate CRs
// from the module's KCC namespace (and waits for them to leave the API; GCP templates follow CNRM CR deletion).
// Cleanup starts as soon as the child Application delete is issued: for workloads-android, waiting only until
// the child CR is gone can deadlock when Argo is blocked on CCC while CCC cannot finalize until CITs are gone.
// The same CIT removal still runs again after the child disappears (idempotent).
// Finally, for workloads-android, wait for the workflows-namespace ConfigConnectorContext to be absent.
//
// moduleConfig may be empty; NamespacePrefixFromModuleConfig then uses MODULE_CONFIG from the environment.
// If the child Application CR is already absent, the parent is still prepared (skip-reconcile, etc.) so Git
// cannot recreate the child before the parent Application is deleted.
func TeardownPrefixedModuleChildApplication(ctx context.Context, c client.Client, argocdNamespace, moduleConfig, moduleName string) (err error) {
	if !ModuleUsesPrefixedChildApplication(moduleName) {
		return nil
	}
	logger := log.FromContext(ctx)
	prefix := NamespacePrefixFromModuleConfig(moduleConfig)
	childName := prefixedModuleChildApplicationName(prefix, moduleName)
	parentName := ApplicationName(moduleName)
	skipOnParent := false
	defer func() {
		if !skipOnParent || err == nil {
			return
		}
		cleanupCtx := context.Background()
		if e := setArgoCDApplicationSkipReconcile(cleanupCtx, c, argocdNamespace, parentName, false); e != nil {
			log.FromContext(ctx).Error(e, "clear skip-reconcile on parent after prefixed child teardown error",
				"application", parentName, "namespace", argocdNamespace)
		}
	}()

	child := &unstructured.Unstructured{}
	child.SetGroupVersionKind(argoCDApplicationGVK)
	child.SetNamespace(argocdNamespace)
	child.SetName(childName)

	if err = c.Get(ctx, client.ObjectKeyFromObject(child), child); err != nil {
		if errors.IsNotFound(err) {
			// Child Application may already be gone (fast delete, manual cleanup, or a prior race). The parent
			// mod-* Application's desired manifest from Git still contains this child, so Argo can recreate it
			// unless we pause parent reconcile (skip-reconcile) before returning — otherwise disable looks like
			// "deleted then synced again" and the child sticks on sync vs missing resources until Terminate.
			if err = preparePrefixedModuleParentAndChildForDelete(ctx, c, argocdNamespace, moduleName, childName); err != nil {
				return fmt.Errorf("prepare parent Argo Application while child %q already absent: %w", childName, err)
			}
			skipOnParent = true
			logger.Info("prefixed module teardown: child Application already absent; prepared parent to prevent Git re-create",
				"module", moduleName, "childApplication", childName, "parentApplication", parentName)
			// Module KCC CRs may remain while CNRM templates were removed out-of-band; still remove them.
			if err := ensureCuttlefishComputeInstanceTemplatesRemoved(ctx, c, moduleConfig, moduleName); err != nil {
				return err
			}
			return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
		}
		return err
	}

	if err = preparePrefixedModuleParentAndChildForDelete(ctx, c, argocdNamespace, moduleName, childName); err != nil {
		return fmt.Errorf("prepare parent/child Argo Applications for delete (%q): %w", moduleName, err)
	}
	skipOnParent = true

	logger.Info("teardown prefixed-module child Application before parent delete", "module", moduleName, "application", childName, "namespace", argocdNamespace)
	if err = c.Delete(ctx, child); err != nil && !errors.IsNotFound(err) {
		return err
	}
	// Unblock CCC during Argo prune: delete pipeline ComputeInstanceTemplate CRs immediately, not only after
	// the child Application CR disappears (see TeardownPrefixedModuleChildApplication godoc).
	if err := ensureCuttlefishComputeInstanceTemplatesRemoved(ctx, c, moduleConfig, moduleName); err != nil {
		return err
	}

	deadline := time.Now().Add(moduleChildApplicationDeleteWait)
	for time.Now().Before(deadline) {
		if err = c.Get(ctx, client.ObjectKeyFromObject(child), child); errors.IsNotFound(err) {
			if err := ensureCuttlefishComputeInstanceTemplatesRemoved(ctx, c, moduleConfig, moduleName); err != nil {
				return err
			}
			return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
		}
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(moduleChildApplicationPollInterval):
		}
	}

	// Stuck in Terminating / Deleting: first strip Argo CD Application finalizers (*.argoproj.io), wait for the CR
	// to disappear, then only as a last resort clear any remaining finalizers.
	return clearStuckPrefixedModuleChildFinalizers(ctx, c, argocdNamespace, childName, moduleName, moduleConfig)
}

func clearStuckPrefixedModuleChildFinalizers(ctx context.Context, c client.Client, argocdNamespace, childName, moduleName, moduleConfig string) error {
	logger := log.FromContext(ctx)
	if err := terminateArgoCDApplicationOperationIfAny(ctx, c, argocdNamespace, childName); err != nil {
		return fmt.Errorf("terminate stuck child Application operation: %w", err)
	}
	if err := ensureCuttlefishComputeInstanceTemplatesRemoved(ctx, c, moduleConfig, moduleName); err != nil {
		return fmt.Errorf("remove module KCC ComputeInstanceTemplate CRs before clearing stuck child Application finalizers: %w", err)
	}
	key := types.NamespacedName{Namespace: argocdNamespace, Name: childName}
	gvk := argoCDApplicationGVK

	tryRemoveArgoFinalizers := func() (gone bool, didStrip bool, err error) {
		fresh := &unstructured.Unstructured{}
		fresh.SetGroupVersionKind(gvk)
		if err := c.Get(ctx, key, fresh); err != nil {
			if errors.IsNotFound(err) {
				return true, false, nil
			}
			return false, false, err
		}
		fs := fresh.GetFinalizers()
		kept, removed := partitionArgoCDFinalizers(fs)
		if len(removed) == 0 {
			return false, false, nil
		}
		fresh.SetFinalizers(kept)
		if err := c.Update(ctx, fresh); err != nil {
			if errors.IsNotFound(err) {
				return true, false, nil
			}
			return false, false, err
		}
		logger.Info("removed Argo CD finalizers from stuck prefixed-module child Application",
			"module", moduleName, "application", childName, "namespace", argocdNamespace,
			"removedFinalizers", removed, "remainingFinalizers", kept)
		return false, true, nil
	}

	gone, didStrip, err := tryRemoveArgoFinalizers()
	if err != nil {
		return err
	}
	if gone {
		return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
	}

	if didStrip {
		deadline := time.Now().Add(moduleChildPostArgoFinalizerWait)
		for time.Now().Before(deadline) {
			fresh := &unstructured.Unstructured{}
			fresh.SetGroupVersionKind(gvk)
			err := c.Get(ctx, key, fresh)
			if errors.IsNotFound(err) {
				return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
			}
			if err != nil {
				return err
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(moduleChildApplicationPollInterval):
			}
		}
	}

	fresh := &unstructured.Unstructured{}
	fresh.SetGroupVersionKind(gvk)
	if err := c.Get(ctx, key, fresh); err != nil {
		if errors.IsNotFound(err) {
			return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
		}
		return err
	}
	fs := fresh.GetFinalizers()
	if len(fs) == 0 {
		return nil
	}

	logger.Info("prefixed-module child Application still present after Argo finalizer strip and wait; clearing all remaining finalizers as last resort",
		"module", moduleName, "application", childName, "namespace", argocdNamespace, "remainingFinalizers", fs)
	patch := []byte(`{"metadata":{"finalizers":[]}}`)
	if err := c.Patch(ctx, fresh, client.RawPatch(types.MergePatchType, patch)); err != nil {
		if errors.IsNotFound(err) {
			return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
		}
		return err
	}
	deadlineAfterNuke := time.Now().Add(moduleChildPostArgoFinalizerWait)
	for time.Now().Before(deadlineAfterNuke) {
		probe := &unstructured.Unstructured{}
		probe.SetGroupVersionKind(gvk)
		err := c.Get(ctx, key, probe)
		if errors.IsNotFound(err) {
			return EnsureWorkflowsConfigConnectorContextRemoved(ctx, c, moduleConfig, moduleName)
		}
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(moduleChildApplicationPollInterval):
		}
	}
	return fmt.Errorf("prefixed-module child Application %s/%s still present after clearing metadata.finalizers; manual delete may be required",
		argocdNamespace, childName)
}

// WaitPrefixedModuleChildApplicationAbsent waits until the child Application is gone before enabling mod-{module}
// again. Fast re-enable while the child is still terminating overlaps delete vs sync and confuses Argo CD status.
func WaitPrefixedModuleChildApplicationAbsent(ctx context.Context, c client.Client, argocdNamespace, moduleConfig, moduleName string) error {
	if !ModuleUsesPrefixedChildApplication(moduleName) {
		return nil
	}
	prefix := NamespacePrefixFromModuleConfig(moduleConfig)
	childName := prefixedModuleChildApplicationName(prefix, moduleName)

	child := &unstructured.Unstructured{}
	child.SetGroupVersionKind(argoCDApplicationGVK)
	child.SetNamespace(argocdNamespace)
	child.SetName(childName)

	deadline := time.Now().Add(moduleChildApplicationDeleteWait)
	for time.Now().Before(deadline) {
		err := c.Get(ctx, client.ObjectKeyFromObject(child), child)
		if errors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(moduleChildApplicationPollInterval):
		}
	}
	return fmt.Errorf("child Application %s/%s still exists after %s; wait for disable to finish or clear stuck finalizers before enabling again",
		argocdNamespace, childName, moduleChildApplicationDeleteWait)
}

// EnsureWorkflowsConfigConnectorContextRemoved waits until no ConfigConnectorContext named
// configconnectorcontext.core.cnrm.cloud.google.com remains in {prefix}workflows. If a live CCC still exists
// (e.g. partial uninstall), it is deleted so CNRM can tear it down after ComputeInstanceTemplate CRs are already
// gone — matching the pre–workloads-android / pre–cf_instance_template cluster baseline on disable.
func EnsureWorkflowsConfigConnectorContextRemoved(ctx context.Context, c client.Client, moduleConfig, moduleName string) error {
	if moduleName != "workloads-android" {
		return nil
	}
	logger := log.FromContext(ctx)
	ns := NamespacePrefixFromModuleConfig(moduleConfig) + "workflows"
	deadline := time.Now().Add(configConnectorContextMaxWait)
	var loggedDelete, loggedWait bool
	var zeroCitStreak int
	var cccFinalizerStripDone bool
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		u, err := getWorkflowsConfigConnectorContext(ctx, c, ns)
		if errors.IsNotFound(err) {
			logger.Info("workloads-android disable: ConfigConnectorContext absent in workflows namespace (baseline)",
				"namespace", ns)
			return nil
		}
		if err != nil {
			return fmt.Errorf("get ConfigConnectorContext in namespace %q during disable teardown: %w", ns, err)
		}
		if u.GetDeletionTimestamp().IsZero() {
			zeroCitStreak = 0
			if !loggedDelete {
				logger.Info("workloads-android disable: deleting ConfigConnectorContext to complete KCC teardown",
					"namespace", ns, "configConnectorContext", configConnectorContextCRName)
				loggedDelete = true
			}
			if err := c.Delete(ctx, u); err != nil && !errors.IsNotFound(err) {
				return fmt.Errorf("delete ConfigConnectorContext %s/%s: %w", ns, configConnectorContextCRName, err)
			}
		} else {
			if !loggedWait {
				logger.Info("workloads-android disable: waiting for ConfigConnectorContext to finish deleting",
					"namespace", ns, "configConnectorContext", configConnectorContextCRName)
				loggedWait = true
			}
			// Addon may report "N ComputeInstanceTemplate(s)" while the API already lists none — unblock CCC.
			ul, listErr := listComputeInstanceTemplates(ctx, c, ns)
			if listErr != nil {
				return fmt.Errorf("list ComputeInstanceTemplate in namespace %q while waiting on ConfigConnectorContext: %w", ns, listErr)
			}
			if cuttlefishComputeInstanceTemplatesRemaining(ul) == 0 {
				zeroCitStreak++
			} else {
				zeroCitStreak = 0
			}
			if !cccFinalizerStripDone &&
				zeroCitStreak >= cccStaleCitZeroCountPollsBeforeFinalizerStrip &&
				configConnectorStatusErrorsLikelyStaleCitBlock(u) {
				logger.Info(
					"workloads-android disable: clearing ConfigConnectorContext metadata.finalizers after sustained zero ComputeInstanceTemplate in API while CCC status references CITs (stale addon/CNRM)",
					"namespace", ns, "configConnectorContext", configConnectorContextCRName, "zeroCitStreak", zeroCitStreak)
				if err := patchConfigConnectorContextStripFinalizers(ctx, c, u); err != nil {
					return fmt.Errorf("stale ConfigConnectorContext teardown (strip finalizers) in namespace %q: %w", ns, err)
				}
				cccFinalizerStripDone = true
				zeroCitStreak = 0
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(configConnectorContextPollInterval):
		}
	}
	return fmt.Errorf(
		"ConfigConnectorContext %s in namespace %q still present after %s; "+
			"check CNRM / GCP finalization or remaining namespaced Config Connector resources in that namespace",
		configConnectorContextCRName, ns, configConnectorContextMaxWait,
	)
}

// getWorkflowsConfigConnectorContext returns the namespaced CCC if present; NotFound when absent on all known GVKs.
func getWorkflowsConfigConnectorContext(ctx context.Context, c client.Client, workflowsNamespace string) (*unstructured.Unstructured, error) {
	key := types.NamespacedName{Namespace: workflowsNamespace, Name: configConnectorContextCRName}
	var lastErr error
	for _, gvk := range configConnectorContextGVKs {
		u := &unstructured.Unstructured{}
		u.SetGroupVersionKind(gvk)
		err := c.Get(ctx, key, u)
		if err == nil {
			return u, nil
		}
		if errors.IsNotFound(err) {
			lastErr = err
			continue
		}
		if meta.IsNoMatchError(err) {
			continue
		}
		return nil, err
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.NewNotFound(schema.GroupResource{Group: "core.cnrm.cloud.google.com", Resource: "configconnectorcontexts"}, configConnectorContextCRName)
}

// configConnectorStatusErrorsLikelyStaleCitBlock returns true when CCC status.errors look like the addon
// wedge "cannot finalize deletion … ComputeInstanceTemplate(s)" while the API may already list zero CIT CRs.
func configConnectorStatusErrorsLikelyStaleCitBlock(u *unstructured.Unstructured) bool {
	if u == nil {
		return false
	}
	errs, found, err := unstructured.NestedStringSlice(u.Object, "status", "errors")
	if err != nil || !found || len(errs) == 0 {
		return false
	}
	for _, e := range errs {
		el := strings.ToLower(e)
		if strings.Contains(el, "computeinstancetemplate") && strings.Contains(el, "cannot finalize deletion") {
			return true
		}
	}
	return false
}

func patchConfigConnectorContextStripFinalizers(ctx context.Context, c client.Client, u *unstructured.Unstructured) error {
	if u == nil {
		return fmt.Errorf("patch ConfigConnectorContext: nil object")
	}
	base := u.DeepCopy()
	patch := []byte(`{"metadata":{"finalizers":[]}}`)
	if err := c.Patch(ctx, base, client.RawPatch(types.MergePatchType, patch)); err != nil {
		return fmt.Errorf("merge patch ConfigConnectorContext %s/%s (clear finalizers): %w", u.GetNamespace(), u.GetName(), err)
	}
	return nil
}

// WaitWorkflowsConfigConnectorContextAbsentOrNotTerminating blocks mod-workloads-android enable until the
// workflows-namespace CCC is either gone or no longer has metadata.deletionTimestamp. Without this,
// Argo can start syncing workloads-android while the previous CCC is still finalizing deletion (blocked
// by pipeline ComputeInstanceTemplate CRs), which surfaces as indefinite "waiting for healthy state of
// ConfigConnectorContext".
func WaitWorkflowsConfigConnectorContextAbsentOrNotTerminating(ctx context.Context, c client.Client, moduleConfig, moduleName string) error {
	if moduleName != "workloads-android" {
		return nil
	}
	logger := log.FromContext(ctx)
	ns := NamespacePrefixFromModuleConfig(moduleConfig) + "workflows"
	deadline := time.Now().Add(configConnectorContextMaxWait)
	var logged bool
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		u, err := getWorkflowsConfigConnectorContext(ctx, c, ns)
		if errors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("get ConfigConnectorContext in namespace %q: %w", ns, err)
		}
		if u.GetDeletionTimestamp().IsZero() {
			return nil
		}
		if !logged {
			logger.Info("enable workloads-android: waiting for prior ConfigConnectorContext to finish terminating before creating mod-* Application",
				"namespace", ns, "configConnectorContext", configConnectorContextCRName)
			logged = true
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(configConnectorContextPollInterval):
		}
	}
	return fmt.Errorf(
		"ConfigConnectorContext %s in namespace %q still has metadata.deletionTimestamp after %s; "+
			"complete prior module disable (remove blocking computeinstancetemplates.compute.cnrm.cloud.google.com CRs or fix CCC finalization) before enabling workloads-android again",
		configConnectorContextCRName, ns, configConnectorContextMaxWait,
	)
}
