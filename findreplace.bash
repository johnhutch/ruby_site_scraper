find . -type f -name "*.html" -exec \
  sed -i '' 's|<link rel="preconnect" href="">|<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Poppins:ital,wght@0,300;0,400;0,500;0,700;1,300;1,400;1,700">\n<script type="text/javascript" crossorigin="anonymous" defer="true" nomodule="nomodule" src="//assets.squarespace.com/@sqs/polyfiller/1.6/legacy.js"></script>\n<script type="text/javascript" crossorigin="anonymous" defer="true" src="//assets.squarespace.com/@sqs/polyfiller/1.6/modern.js"></script>|g' {} +

