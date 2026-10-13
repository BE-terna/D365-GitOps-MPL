D365FO has it's metadata stored in xml files

locally we have clone in /workspaces/d365fo-preview/d365
sturcture next is package/_model_ (where there is aslo a package/Descriptor/_model_.xml)
inside a _model_ thara are many AxType folders (like AxClass AxTable). 
Each element has it xml root object with the same name as folder name like `<AxClass />`

inside a xml order of the tags is in general important (like order of the fields in the database index)
in some cases order isn't important (like order of indexes in the table).
in case of a conflict create custom merger

for example in table order of a fileds isn't important
xml path: /AxTable/Fields/AxTableField

similar example for permissions in privileges
xml path: /AxSecurityPrivilege/EntryPoints/AxSecurityEntryPointReference (enitre subtree must be unchanged, merged as siblings)

when two developers changes same document (for example one adds index A, second adds index B)
git merge returns an error as it both are inside Indexes element
but we know the order here isn't important
so we would like to solve such merge conflics automatically (like we did in txt merge driver /workspaces/D365-GitOps-MPL/D365GitOps/functions/MergeDrivers/Merge-D365LabelFile.ps1)

we want similar pwsh based merge driver for xml elements
one of the parameters (env variable? any other idea) should be file with rules (generate sample with defaults)
we also want to distribute default rules
idea of the rules is to be new line separated XPaths of the elements where order of sibling nodes doesn't matter, you can suggest better option

this merge driver will be used by developers and by a CI/CD automation where we merge all open pull requests (it must be os/agent agnostic)

for test use
/workspaces/D365-GitOps-MPL/D365GitOps/functions/MergeDrivers/
- initial base: Sample-Base.xml
- user 1: Sample-Base-C001.xml
- user 2: Sample-Base-C002.xml
- expected result: Sample-Base-Expected-a.xml or Sample-Base-Expected-a.xml (acceptance criteria - order is not important/one or another)

if you have any additional questions or thera are some things unclear: ask