// Copyright (c) 2026 RemotiveLabs, All Rights Reserved.
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
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

var citGVK = schema.GroupVersionKind{Group: "compute.cnrm.cloud.google.com", Version: "v1beta1", Kind: "ComputeInstanceTemplate"}

func TestModuleComputeInstanceTemplateNamespace(t *testing.T) {
	t.Setenv("MODULE_CONFIG", "")
	cases := []struct {
		module, config, wantNS string
		wantOK                 bool
	}{
		{"workloads-android", "", "workflows", true},
		{"workloads-android", "namespacePrefix: sbx-\n", "sbx-workflows", true},
		{"remotive-topology", "", "remotive-kcc", true},
		{"remotive-topology", "namespacePrefix: sbx-\n", "sbx-remotive-kcc", true},
		{"workloads-common", "namespacePrefix: sbx-\n", "", false},
		{"sample", "", "", false},
	}
	for _, tc := range cases {
		ns, ok := moduleComputeInstanceTemplateNamespace(tc.config, tc.module)
		if ns != tc.wantNS || ok != tc.wantOK {
			t.Errorf("moduleComputeInstanceTemplateNamespace(%q, %q) = (%q, %v), want (%q, %v)",
				tc.config, tc.module, ns, ok, tc.wantNS, tc.wantOK)
		}
	}
}

// newCITFakeClient registers the CNRM ComputeInstanceTemplate kinds so List/Delete work on unstructured objects.
func newCITFakeClient(objs ...client.Object) client.Client {
	s := runtime.NewScheme()
	s.AddKnownTypeWithName(citGVK, &unstructured.Unstructured{})
	s.AddKnownTypeWithName(schema.GroupVersionKind{Group: citGVK.Group, Version: citGVK.Version, Kind: citGVK.Kind + "List"}, &unstructured.UnstructuredList{})
	return fake.NewClientBuilder().WithScheme(s).WithObjects(objs...).Build()
}

func citNames(t *testing.T, c client.Client, ns string) []string {
	t.Helper()
	ul, err := listComputeInstanceTemplates(context.Background(), c, ns)
	if err != nil {
		t.Fatalf("list %s: %v", ns, err)
	}
	var names []string
	for i := range ul.Items {
		names = append(names, ul.Items[i].GetName())
	}
	return names
}

// Disabling remotive-topology removes every ComputeInstanceTemplate in its own KCC namespace and nothing in the
// shared workflows namespace (the workloads-android cf-it-* CRs).
func TestEnsureComputeInstanceTemplatesRemoved_remotiveScopedToOwnNamespace(t *testing.T) {
	t.Setenv("MODULE_CONFIG", "")
	c := newCITFakeClient(
		mustCit(t, "sbx-remotive-kcc", "remotive-it-instance-template-remotive-vm", map[string]string{"horizon-sdv.io/remotive-kcc-template": "true"}),
		mustCit(t, "sbx-remotive-kcc", "unlabeled-leftover", nil),
		mustCit(t, "sbx-workflows", "cf-it-cuttlefish", map[string]string{"horizon-sdv.io/cuttlefish-kcc-template": "true"}),
	)
	if err := ensureCuttlefishComputeInstanceTemplatesRemoved(context.Background(), c, "namespacePrefix: sbx-\n", "remotive-topology"); err != nil {
		t.Fatalf("remotive teardown: %v", err)
	}
	if got := citNames(t, c, "sbx-remotive-kcc"); len(got) != 0 {
		t.Errorf("remotive KCC namespace still has %v", got)
	}
	if got := citNames(t, c, "sbx-workflows"); len(got) != 1 || got[0] != "cf-it-cuttlefish" {
		t.Errorf("workflows namespace changed: %v", got)
	}
}

// Disabling workloads-android must not touch remotive's dedicated namespace.
func TestEnsureComputeInstanceTemplatesRemoved_androidLeavesRemotiveNamespace(t *testing.T) {
	t.Setenv("MODULE_CONFIG", "")
	c := newCITFakeClient(
		mustCit(t, "remotive-kcc", "remotive-it-instance-template-remotive-vm", map[string]string{"horizon-sdv.io/remotive-kcc-template": "true"}),
		mustCit(t, "workflows", "cf-it-cuttlefish", map[string]string{"horizon-sdv.io/cuttlefish-kcc-template": "true"}),
	)
	if err := ensureCuttlefishComputeInstanceTemplatesRemoved(context.Background(), c, "", "workloads-android"); err != nil {
		t.Fatalf("android teardown: %v", err)
	}
	if got := citNames(t, c, "workflows"); len(got) != 0 {
		t.Errorf("workflows namespace still has %v", got)
	}
	if got := citNames(t, c, "remotive-kcc"); len(got) != 1 {
		t.Errorf("remotive KCC namespace changed: %v", got)
	}
}

func TestEnsureComputeInstanceTemplatesRemoved_noKCCModuleIsNoOp(t *testing.T) {
	t.Setenv("MODULE_CONFIG", "")
	c := newCITFakeClient(mustCit(t, "workflows", "cf-it-cuttlefish", nil))
	if err := ensureCuttlefishComputeInstanceTemplatesRemoved(context.Background(), c, "", "workloads-common"); err != nil {
		t.Fatalf("workloads-common: %v", err)
	}
	if got := citNames(t, c, "workflows"); len(got) != 1 {
		t.Errorf("workloads-common teardown must not delete CITs; got %v", got)
	}
}

func TestWaitModuleKCCNamespaceNotTerminating(t *testing.T) {
	t.Setenv("MODULE_CONFIG", "")
	nsGVK := schema.GroupVersionKind{Version: "v1", Kind: "Namespace"}
	live := &unstructured.Unstructured{}
	live.SetGroupVersionKind(nsGVK)
	live.SetName("remotive-kcc")
	c := newKCCFakeClient(nsGVK, live)

	// Namespace present and not terminating → proceed.
	if err := WaitModuleKCCNamespaceNotTerminating(context.Background(), c, "", "remotive-topology"); err != nil {
		t.Fatalf("live namespace: %v", err)
	}
	// Namespace absent → proceed (parent chart will create it).
	if err := WaitModuleKCCNamespaceNotTerminating(context.Background(), c, "namespacePrefix: sbx-\n", "remotive-topology"); err != nil {
		t.Fatalf("absent namespace: %v", err)
	}
	// Other modules are never checked, even with a client that cannot read namespaces.
	if err := WaitModuleKCCNamespaceNotTerminating(context.Background(), newCITFakeClient(), "", "workloads-android"); err != nil {
		t.Fatalf("workloads-android: %v", err)
	}
}
