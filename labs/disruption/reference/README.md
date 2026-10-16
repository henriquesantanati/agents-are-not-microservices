# Karpenter reference

Karpenter provisions cloud nodes and cannot run on `kind`, so no script applies these
manifests. They show the complete, copyable pattern.

`nodepool.yaml` sets `terminationGracePeriod` on the NodePool, so a pod annotated
`karpenter.sh/do-not-disrupt` can delay a node's disruption but never block it forever.

- [Karpenter disruption concepts](https://karpenter.sh/docs/concepts/disruption/)
  defines `do-not-disrupt`, `terminationGracePeriod` and how they interact.
