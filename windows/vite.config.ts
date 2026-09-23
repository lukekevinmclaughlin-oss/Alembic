import{defineConfig}from'vite';
export default defineConfig({server:{watch:{ignored:['**/release/**','**/build/**','**/electron/**']}},build:{emptyOutDir:true}});
