# Manifest Maintenance (Developers)

Keep [`vss-extension.json`](vss-extension.json) minimal and consistent.

- Do not maintain version here; publishing GitHub Action overrides it.
- Do not maintain publisher here; publishing GitHub Action overrides it.
- Keep id, contribution id, task folder path, and properties.name in sync.
- If you rename/move files, update paths in files[] and contributions[].
- Keep icon paths valid under [images/](images/).
- Verify with:

```bash
tfx extension create --manifest-globs vss-extension.json --root azure-devops-extension --output-path .
```

## Reference: 
- https://learn.microsoft.com/azure/devops/extend/develop/manifest
- https://learn.microsoft.com/en-us/azure/devops/extend/develop/add-build-task?toc=%2Fazure%2Fdevops%2Fmarketplace-extensibility%2Ftoc.json&view=azure-devops#taskjson-components

### PowerShell tasks
- https://github.com/microsoft/azure-pipelines-task-lib/tree/master/powershell/Docs/#readme
- https://github.com/microsoft/azure-pipelines-task-lib/blob/master/powershell/Docs/TestingAndDebugging.md
