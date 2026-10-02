# Add unseal secrets

- threshold keys secret (same namespace as the `Unseal` CR; the controller runs its unseal Jobs there)

```sh
kubectl create secret generic thresholdkeys -n vault-unseal-controller-system --from-literal key1=YOUR_KEY \
  --from-literal key2=YOUR_KEY \
  --from-literal key3=YOUR_KEY
```
