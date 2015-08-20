#!/bin/sh

# Install Data-Repo Sufia application

PLATFORM=$1
BOOTSTRAP_DIR=$2
# Read settings and environmental overrides
[ -f "${BOOTSTRAP_DIR}/config.sh" ] && . "${BOOTSTRAP_DIR}/config.sh"
[ -f "${BOOTSTRAP_DIR}/config_${PLATFORM}.sh" ] && . "${BOOTSTRAP_DIR}/config_${PLATFORM}.sh"

# Install Java 8 and make it the default Java
add-apt-repository -y ppa:webupd8team/java
apt-get update -y
echo oracle-java8-installer shared/accepted-oracle-license-v1-1 select true | /usr/bin/debconf-set-selections
apt-get install -y oracle-java8-installer
update-java-alternatives -s java-8-oracle

# Install FITS
apt-get install -y unzip
$RUN_AS_INSTALLUSER mkdir -p $FITS_DIR
cd "$FITS_DIR"
$RUN_AS_INSTALLUSER wget --quiet "http://projects.iq.harvard.edu/files/fits/files/${FITS_PACKAGE}.zip"
$RUN_AS_INSTALLUSER unzip -q ${FITS_DIR}/${FITS_PACKAGE}.zip
chmod a+x ${FITS_DIR}/${FITS_PACKAGE}/fits.sh
cd $INSTALL_DIR

# Install ffmpeg
# Instructions from the static builds link on this page: https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu
add-apt-repository -y ppa:mc3man/trusty-media
apt-get update
apt-get install -y ffmpeg

# Install nodejs from Nodesource
curl -sL https://deb.nodesource.com/setup | bash -
apt-get install -y nodejs

# Install Redis, ImageMagick, PhantomJS, and Libre Office
apt-get install -y redis-server imagemagick phantomjs libreoffice
# Install Ruby via Brightbox repository
add-apt-repository -y ppa:brightbox/ruby-ng
apt-get update
apt-get install -y $RUBY_PACKAGE ${RUBY_PACKAGE}-dev

# Install Nginx and Passenger.
# Install the Phusion Passenger APT repository
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 561F9B9CAC40B2F7
#sudo apt-get install apt-transport-https ca-certificates # Not necessary for 14_04, but part of the Phusion Docs.
echo "deb https://oss-binaries.phusionpassenger.com/apt/passenger trusty main" > $PASSENGER_REPO
chown root: $PASSENGER_REPO
chmod 600 $PASSENGER_REPO
apt-get update
# Install Nginx and Passenger
apt-get install -y nginx-extras passenger
# Uncomment passenger_root and passenger_ruby lines from config file
TMPFILE=`/bin/mktemp`
cat $NGINX_CONF_FILE | \
  sed "s/# passenger_root/passenger_root/" | \
  sed "s/# passenger_ruby/passenger_ruby/" > $TMPFILE
sed "1ienv PATH;" < $TMPFILE > $NGINX_CONF_FILE
chown root: $NGINX_CONF_FILE
chmod 644 $NGINX_CONF_FILE
# Disable the default site
unlink ${NGINX_CONF_DIR}/sites-enabled/default
# Stop Nginx until the application is installed
service nginx stop

# Configure Passenger to serve our site.
# Create the virtual host for our Sufia application
cat > $TMPFILE <<HereDoc
server {
    listen 80;
    listen 443 ssl;
    client_max_body_size 200M;
    root ${HYDRA_HEAD_DIR}/public;
    passenger_enabled on;
    passenger_app_env ${APP_ENV};
    server_name ${SERVER_HOSTNAME};
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
}
HereDoc
# Install the virtual host config as an available site
install -o root -g root -m 644 $TMPFILE $NGINX_SITE
rm $TMPFILE
# Enable the site just created
link $NGINX_SITE ${NGINX_CONF_DIR}/sites-enabled/${HYDRA_HEAD}.site
# Create the directories for the SSL certificate files
mkdir -p $SSL_CERT_DIR
mkdir -p $SSL_KEY_DIR
install -o root -m 444 ${BOOTSTRAP_DIR}/files/cert $SSL_CERT
install -o root -m 400 ${BOOTSTRAP_DIR}/files/key $SSL_KEY

# Create Hydra head
apt-get install -y git sqlite3 libsqlite3-dev zlib1g-dev build-essential
gem install --no-document rails -v "$RAILS_VERSION"
$RUN_AS_INSTALLUSER rails new $HYDRA_HEAD $HYDRA_HEAD_DIR

# Add and set up Sufia
cd $HYDRA_HEAD_DIR
$RUN_AS_INSTALLUSER echo "gem 'sufia', '$SUFIA_VERSION'" >> $HYDRA_HEAD_DIR/Gemfile
$RUN_AS_INSTALLUSER echo "gem 'kaminari', github: 'jcoyne/kaminari', branch: 'sufia'" >> $HYDRA_HEAD_DIR/Gemfile
$RUN_AS_INSTALLUSER bundle install
$RUN_AS_INSTALLUSER rails generate sufia:install -f
$RUN_AS_INSTALLUSER bundle exec rake db:migrate

# Pull from git. This fixes application configuration
$RUN_AS_INSTALLUSER git init
$RUN_AS_INSTALLUSER git remote add origin "https://github.com/$HYDRA_HEAD_GIT_REPO.git"
$RUN_AS_INSTALLUSER git fetch --all
$RUN_AS_INSTALLUSER git reset --hard origin/master
$RUN_AS_INSTALLUSER bundle install

# Setup the application

# 1. Create a migration: rails generate migration CreateDoiRequests
$RUN_AS_INSTALLUSER bundle exec rails generate migration CreateDoiRequests
DOI_MIGRATION_FILE=`find db/migrate -type f -name '*_create_doi_requests.rb'|sort|tail -1`
# 2. Replace the contents of the new migration with this gist: https://gist.github.com/tingtingjh/ab35348f493d565cdcc8
$RUN_AS_INSTALLUSER cat > $DOI_MIGRATION_FILE <<GIST
class CreateDoiRequests < ActiveRecord::Migration
  def change
    create_table :doi_requests do |t|
      t.string "collection_id"
      t.string "ezid_doi", default: "doi:pending", null: false
      t.string "asset_type", default: "Collection", null: false
      t.boolean "completed", default: false
      t.timestamps null: false
    end
    add_index :doi_requests, :ezid_doi
    add_index :doi_requests, :collection_id
  end
end
GIST
# 3. Generate Role model: rails generate roles
$RUN_AS_INSTALLUSER bundle exec rails generate roles
# 4. Remove the before filter added to app/controllers/application_controller.rb
$RUN_AS_INSTALLUSER sed -i '/^  before_filter do$/,/^  end$/d' app/controllers/application_controller.rb
# 5. Migrate
$RUN_AS_INSTALLUSER bundle exec rake db:migrate
# 6. Create default roles and an admin user
$RUN_AS_INSTALLUSER bundle exec rake datarepo:setup_defaults
# 7. Install Orcid
$RUN_AS_INSTALLUSER bundle exec rails generate orcid:install --skip-application-yml
# 8. Revert changes already incorporated
$RUN_AS_INSTALLUSER git checkout ./app/models/user.rb ./config/routes.rb

# Application Deployment steps.
cd $HYDRA_HEAD_DIR
$RUN_AS_INSTALLUSER bundle install
$RUN_AS_INSTALLUSER rails g migration AddOmniauthToUsers provider uid
$RUN_AS_INSTALLUSER rake db:migrate
if [ "$APP_ENV" = "production" ]; then
    $RUN_AS_INSTALLUSER bundle install --deployment --without development test
    # Deploy production ORCID secrets from ${BOOTSTRAP_DIR}/files/orcid_secrets if they exist
    if [ -f ${BOOTSTRAP_DIR}/files/orcid_secrets ]; then
      NEW_ORCID_APP_ID=$(grep ORCID_APP_ID ${BOOTSTRAP_DIR}/files/orcid_secrets)
      NEW_ORCID_APP_SECRET=$(grep ORCID_APP_SECRET ${BOOTSTRAP_DIR}/files/orcid_secrets)
      $RUN_AS_INSTALLUSER sed -i "s/ORCID_APP_ID: 0000-0000-0000-0000/$NEW_ORCID_APP_ID/" "$HYDRA_HEAD_DIR/config/application.yml"
      $RUN_AS_INSTALLUSER sed -i "s/ORCID_APP_SECRET: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/$NEW_ORCID_APP_SECRET/" "$HYDRA_HEAD_DIR/config/application.yml"
    else
      echo 'Warning: No production orcid_secrets file supplied; using defaults!'
    fi
    # Point to production CAS
    $RUN_AS_INSTALLUSER sed -i 's/config.omniauth \(.*\)cas-dev.middleware.vt.edu/config.omniauth \1auth.vt.edu/' "$HYDRA_HEAD_DIR/config/initializers/devise.rb"
    # Install Application secret key
    $RUN_AS_INSTALLUSER sed --in-place=".bak" --expression="s|<%= ENV\[\"SECRET_KEY_BASE\"\] %>|$(bundle exec rake secret)|" "$HYDRA_HEAD_DIR/config/secrets.yml"
    $RUN_AS_INSTALLUSER RAILS_ENV=production bundle exec rake db:setup
    $RUN_AS_INSTALLUSER RAILS_ENV=production bundle exec rake assets:precompile
    $RUN_AS_INSTALLUSER RAILS_ENV=production bundle exec rake datarepo:setup_defaults
fi
# Fix up configuration files
# 1. FITS
$RUN_AS_INSTALLUSER sed -i "s@config.fits_path = \".*\"@config.fits_path = \"$FITS_DIR/$FITS_PACKAGE/fits.sh\"@" config/initializers/sufia.rb
cd $HYDRA_HEAD_DIR
# 3. Make the solr.yml file point to an appropriate $APP_ENV core
sed -i '/production:/ {N; s@^production:.*development@production:\n  url: http://localhost:8983/solr/production@}' config/solr.yml
# 4. Make the blacklight.yml file point to an appropriate $APP_ENV core
sed -i '/production:/ {N; N; s@^production:\(.*\)/development@production:\1/production@}' config/blacklight.yml
# 5. Make the fedora.yml point to Tomcat 7 port, not to hydra-jetty port 8983
sed -i 's/url:\(.*\):8983/url:\1:8080/' config/fedora.yml