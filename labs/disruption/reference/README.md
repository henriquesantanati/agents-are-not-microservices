# Karpenter reference

These manifests are not run. Karpenter provisions cloud nodes and cannot run on `kind`.
They are here so the pattern on slide 14 has a complete, copyable form.

`nodepool.yaml` sets `terminationGracePeriod` on the NodePool, so a pod annotated
`karpenter.sh/do-not-disrupt` can delay a node's disruption but never block it forever.

- [Karpenter disruption concepts](https://karpenter.sh/docs/concepts/disruption/)
  defines `do-not-disrupt`, `terminationGracePeriod` and how they interact.
