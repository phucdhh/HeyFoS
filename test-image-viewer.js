import fs from 'fs'
const c = fs.readFileSync('frontend/src/ImageViewer.js', 'utf8')
console.log(c.includes('scrollIntoView') ? "HAS SCROLL" : "NO SCROLL")
