#!/bin/bash

cp apis/definition.yaml cr-definition.yaml
sed -i 's/CompositeResourceDefinition/CustomResourceDefinition/' cr-definition.yaml
sed -i 's/apiextensions.crossplane.io\/v1/apiextensions.k8s.io\/v1/g' cr-definition.yaml 

crdoc -r cr-definition.yaml -o docs/apis/definition.md