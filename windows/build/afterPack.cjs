const path=require('node:path');
exports.default=async context=>{
  if(context.electronPlatformName!=='win32')return;
  const {rcedit}=await import('rcedit');
  const info=context.packager.appInfo;
  await rcedit(path.join(context.appOutDir,info.productFilename+'.exe'),{
    icon:path.join(context.packager.projectDir,'build/icon.ico'),
    'file-version':info.version,'product-version':info.version,
    'version-string':{CompanyName:'Luke McLaughlin',FileDescription:'Local dataset preparation and RAG chunking for Windows',ProductName:info.productName,OriginalFilename:info.productFilename+'.exe'}
  });
};
