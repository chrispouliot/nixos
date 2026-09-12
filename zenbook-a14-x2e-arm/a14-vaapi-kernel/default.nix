# Import only if the running kernel lacks the bridge's decoder prerequisites.
# Intended for linux-msm 51231839d5ef with the A14 Iris video patches.
{ ... }: {
  boot.kernelPatches = [
    { name = "a14-iris-vaapi-decode-order"; patch = ./iris-decode-order.patch; }
    { name = "a14-iris-vaapi-capture-pool"; patch = ./iris-capture-pool.patch; }
  ];
}
