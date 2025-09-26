A script for scraping a site. 

To run: 

# Change the target site in the code (or update it to accept command line parameters like I meant to do but was lazy). 
# `bundle config set path 'vendor/bundle'` to ensure gems don't get installed globally
# `bundle install`
# bundle exec ruby site_scraper.rb`

There's also an included find/replace bash script in case you have to update some shit in your code since the site_scraper will generally not catch code that's updated by JS after page load.
