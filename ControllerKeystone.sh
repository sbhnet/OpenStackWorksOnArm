# Controller Only Below

# sanity check - make sure we can reach the controller
ping controller -c 5 -q
if [ $? -ne 0 ] ; then
  echo "controller is unreachable"
  echo "check /etc/hosts and networking and then restart this script"
  exit -1
fi

# private IP addr (10...)
MY_IP=`hostname -I | xargs -n1 | grep "^10\." | head -1`


# general system updates
apt-get -y update

# non-interactively set a timezone so we're not interactively prompted
export DEBIAN_FRONTEND=noninteractive
apt-get install -y tzdata
ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# OpenStack needs precise time services
apt-get -y install chrony
service chrony restart

apt -y install software-properties-common
add-apt-repository -y cloud-archive:pike
apt -y update
apt -y install python-openstackclient


# easy modification of .ini configuration files
apt-get -y install crudini


## rabbitmq
apt -y install rabbitmq-server
rabbitmqctl add_user openstack RABBIT_PASS
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
## end of rabbitmq

## memcached
apt -y install memcached python-memcache
# set the IP where memchaced is listening
sed -i '/^-l.*/c\-l '$MY_IP /etc/memcached.conf
service memcached restart

cat > /etc/etcd/etcd.conf.yml << EOF
name: controller
data-dir: /var/lib/etcd
initial-cluster-state: 'new'
initial-cluster-token: 'etcd-cluster-01'
initial-cluster: controller=http://${MY_IP}:2380
initial-advertise-peer-urls: http://${MY_IP}:2380
advertise-client-urls: http://${MY_IP}:2379
listen-peer-urls: http://0.0.0.0:2380
listen-client-urls: http://${MY_IP}:2379
EOF
## end of memcached

## etcd
cat > /lib/systemd/system/etcd.service << EOF
[Unit]
After=network.target
Description=etcd - highly-available key value store

[Service]
Environment="ETCD_UNSUPPORTED_ARCH=arm64"
LimitNOFILE=65536
Restart=on-failure
Type=notify
ExecStart=/usr/bin/etcd --config-file /etc/etcd/etcd.conf.yml
User=etcd

[Install]
WantedBy=multi-user.target
EOF

systemctl enable etcd
systemctl start etcd
## end of etcd

## mysql
apt -y install mariadb-server python-pymysql


cat >> /etc/mysql/mariadb.conf.d/99-openstack.cnf << EOF
[mysqld]
bind-address = ${MY_IP}

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

service mysql restart

# harden MySQL
# mysql_secure_installation
## end of mysql

## keystone
mysql --batch -e "\
CREATE DATABASE keystone; \
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'KEYSTONE_DBPASS'; \
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY 'KEYSTONE_DBPASS'; \
FLUSH PRIVILEGES"

# Keystone Packages
apt-get -y install keystone  apache2 libapache2-mod-wsgi

crudini --set /etc/keystone/keystone.conf database connection mysql+pymysql://keystone:KEYSTONE_DBPASS@controller/keystone
crudini --set /etc/keystone/keystone.conf token provider fernet

su -s /bin/sh -c "keystone-manage db_sync" keystone

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

keystone-manage bootstrap --bootstrap-password ADMIN_PASS \
  --bootstrap-admin-url http://controller:35357/v3/ \
  --bootstrap-internal-url http://controller:5000/v3/ \
  --bootstrap-public-url http://controller:5000/v3/ \
  --bootstrap-region-id RegionOne

echo "ServerName controller" >> /etc/apache2/apache2.conf
service apache2 restart

  
cat >> admin-openrc << EOF
export OS_USERNAME=admin
export OS_PASSWORD=ADMIN_PASS
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:35357/v3
export OS_IDENTITY_API_VERSION=3
EOF

cat >> demo-openrc << EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=DEMO_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

. admin-openrc

openstack project create --domain default \
  --description "Service Project" service
  
openstack project create --domain default \
  --description "Demo Project" demo
  
openstack user create --domain default \
  --password DEMO_PASS demo
  
openstack role create user

openstack role add --project demo --user demo user

# small sanity check
. admin-openrc
openstack token issue

if [ $? -ne 0 ]; then
  echo "issues generating a keystone token"
else
  echo "successfully issued a keystone token"
fi
## end of keystone



