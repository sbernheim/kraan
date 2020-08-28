/*


Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controllers

import (
	"context"
	"fmt"

	kraanv1alpha1 "github.com/fidelity/kraan/pkg/api/v1alpha1"
	"github.com/fidelity/kraan/pkg/internal/apply"
	layers "github.com/fidelity/kraan/pkg/internal/layers"
	utils "github.com/fidelity/kraan/pkg/internal/utils"

	helmopv1 "github.com/fluxcd/helm-operator/pkg/apis/helm.fluxcd.io/v1"
	"github.com/go-logr/logr"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// AddonsLayerReconciler reconciles a AddonsLayer object.
type AddonsLayerReconciler struct {
	client.Client
	Config   *rest.Config
	k8client *kubernetes.Clientset
	Log      logr.Logger
	Scheme   *runtime.Scheme
	Context  context.Context
	Applier  apply.LayerApplier
}

// NewReconciler returns an AddonsLayerReconciler instance
func NewReconciler(config *rest.Config, client client.Client, logger logr.Logger,
	scheme *runtime.Scheme) (reconciler *AddonsLayerReconciler, err error) {
	reconciler = &AddonsLayerReconciler{
		Config: config,
		Client: client,
		Log:    logger,
		Scheme: scheme,
	}
	reconciler.k8client = reconciler.getK8sClient()
	reconciler.Context = context.Background()
	reconciler.Applier, err = apply.NewApplier(client, logger, scheme)
	return reconciler, err
}

func (r *AddonsLayerReconciler) getK8sClient() *kubernetes.Clientset {
	// creates the clientset
	clientset, err := kubernetes.NewForConfig(r.Config)
	if err != nil {
		//TODO - Adjust error handling?
		panic(err.Error())
	}

	return clientset
}

func processAddonLayer(l layers.Layer) error { // nolint:gocyclo // ok
	utils.Log(l.GetLogger(), 2, 1, "processing", "Status", l.GetStatus())

	if l.IsHold() {
		l.SetHold()
		return nil
	}

	if !l.CheckK8sVersion() {
		l.SetStatusK8sVersion()
		l.SetDelayed()
		return nil
	}

	if l.IsPruningRequired() || l.IsApplyRequired() {
		if err := l.SetAllPrunePending(); err != nil {
			return err
		}
	}

	if l.IsPruningRequired() {
		l.SetStatusPruning()
		if err := l.Prune(); err != nil {
			return err
		}
		l.SetDelayed()
		return nil
	}

	l.SetStatusPruningToPruned()

	if l.AllPruned() {
		if err := l.SetAllPrunedToApplyPending(); err != nil {
			return err
		}
	}

	if !l.DependenciesDeployed() {
		l.SetStatusApplyPending()
		l.SetDelayed()
		return nil
	}

	if l.IsApplyRequired() {
		l.SetStatusApplying()
		if err := l.Apply(); err != nil {
			return err
		}
		l.SetDelayed()
		return nil
	}

	if l.SuccessfullyApplied() {
		l.SetStatusDeployed()
	}
	return nil
}

// Reconcile process AddonsLayers custom resources.
// +kubebuilder:rbac:groups=kraan.io,resources=addons,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=kraan.io,resources=addons/status,verbs=get;update;patch
func (r *AddonsLayerReconciler) Reconcile(req ctrl.Request) (ctrl.Result, error) {
	ctx := r.Context

	var addonsLayer *kraanv1alpha1.AddonsLayer = &kraanv1alpha1.AddonsLayer{}
	if err := r.Get(ctx, req.NamespacedName, addonsLayer); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	log := r.Log.WithValues(
		"requestNamespace", req.NamespacedName.Namespace,
		"requestName", req.NamespacedName.Name)

	l := layers.CreateLayer(ctx, r.Client, r.k8client, log, addonsLayer)

	err := processAddonLayer(l)
	if err != nil {
		l.StatusUpdate(kraanv1alpha1.FailedCondition, kraanv1alpha1.AddonsLayerFailedReason, err.Error())
	}

	if l.IsUpdated() {
		if e := r.update(ctx, log, addonsLayer); e != nil {
			return ctrl.Result{Requeue: true}, e
		}
	}
	if l.NeedsRequeue() {
		if l.IsDelayed() {
			return ctrl.Result{RequeueAfter: l.GetDelay()}, err
		}
		return ctrl.Result{Requeue: true}, err
	}
	return ctrl.Result{}, err
}

func (r *AddonsLayerReconciler) update(ctx context.Context, log logr.Logger,
	a *kraanv1alpha1.AddonsLayer) error {
	if err := r.Status().Update(ctx, a); err != nil {
		log.Error(err, "unable to update AddonsLayer status")
		return err
	}

	return nil
}

/*
func (r *AddonsLayerReconciler) gitRepositorySource(o handler.MapObject) []ctrl.Request {
	//ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	//defer cancel()

	return []ctrl.Request{
		{
			NamespacedName: types.NamespacedName{
				//Name:      sourcev1.GitRepository.Name,
				//Namespace: sourcev1.GitRepository.Namespace,
			},
		},
	}
}
*/

func indexHelmReleaseByOwner(o runtime.Object) []string {
	hr, ok := o.(*helmopv1.HelmRelease)
	if !ok {
		return nil
	}
	owner := metav1.GetControllerOf(hr)
	if owner == nil {
		return nil
	}
	if owner.APIVersion != kraanv1alpha1.GroupVersion.String() || owner.Kind != "AddonsLayer" {
		return nil
	}
	return []string{owner.Name}
}

// SetupWithManager is used to setup the controller
func (r *AddonsLayerReconciler) SetupWithManager(mgr ctrl.Manager) error {
	addonsLayer := &kraanv1alpha1.AddonsLayer{}
	hr := &kraanv1alpha1.AddonsLayer{}
	_, err := ctrl.NewControllerManagedBy(mgr).
		For(addonsLayer).
		/*		Watches(
				&source.Kind{Type: &sourcev1.GitRepository{}},
				&handler.EnqueueRequestsFromMapFunc{
					ToRequests: handler.ToRequestsFunc(r.gitRepositorySource),
				},
			).*/
		Owns(hr).
		Build(r)

	if err != nil {
		return fmt.Errorf("failed setting up the AddonsLayer controller manager: %w", err)
	}
	/*
		if err = c.Watch(
			&source.Kind{Type: &*sourcev1.GitRepository{}},
			&handler.EnqueueRequestsFromMapFunc{
				ToRequests: controllers.ClusterToInfrastructureMapFunc(awsManagedControlPlane.GroupVersionKind()),
			}); err != nil {
			return fmt.Errorf("failed adding a watch for ready clusters: %w", err)
		}
	*/
	if err := mgr.GetFieldIndexer().IndexField(&helmopv1.HelmRelease{}, ".owner", indexHelmReleaseByOwner); err != nil {
		return fmt.Errorf("failed setting up FieldIndexer for HelmRelease owner: %w", err)
	}

	//return ctrl.NewControllerManagedBy(mgr).For(addonsLayer).Owns(hr).Complete(r)
	return nil
}
