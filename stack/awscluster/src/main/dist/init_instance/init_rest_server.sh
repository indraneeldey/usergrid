#!/bin/bash

# 
#  Licensed to the Apache Software Foundation (ASF) under one or more
#   contributor license agreements.  The ASF licenses this file to You
#  under the Apache License, Version 2.0 (the "License"); you may not
#  use this file except in compliance with the License.
#  You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.  For additional information regarding
#  copyright in this work, please see the NOTICE file in the top level
#  directory of this distribution.
#

echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
hostname `cat /etc/hostname`

echo "US/Eastern" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

PKGS="openjdk-7-jdk tomcat7 s3cmd ntp unzip groovy"
apt-get update
apt-get -y --force-yes install ${PKGS}
/etc/init.d/tomcat7 stop

# Install AWS Java SDK and get it into the Groovy classpath
curl http://sdk-for-java.amazonwebservices.com/latest/aws-java-sdk.zip > /tmp/aws-sdk-java.zip
cd /usr/share/
unzip /tmp/aws-sdk-java.zip 
mkdir -p /home/ubuntu/.groovy/lib
cp /usr/share/aws-java-sdk-*/third-party/*/*.jar /home/ubuntu/.groovy/lib
cp /usr/share/aws-java-sdk-*/lib/* /home/ubuntu/.groovy/lib 
ln -s /home/ubuntu/.groovy /root/.groovy

# Build environment for Groovy scripts
. /etc/profile.d/aws-credentials.sh
. /etc/profile.d/usergrid-env.sh
chmod +x /usr/share/usergrid/update.sh

cd /usr/share/usergrid/init_instance
./install_oraclejdk.sh 

cd /usr/share/usergrid/init_instance
./install_yourkit.sh

# set Tomcat memory and threads based on instance type
export NOFILE=100000
case `(curl http://169.254.169.254/latest/meta-data/instance-type)` in
'm1.small' )
    export TOMCAT_RAM=1250M
    export TOMCAT_THREADS=300
;;
'm1.medium' )
    export TOMCAT_RAM=3G
    export TOMCAT_THREADS=500
;;
'm1.large' )
    export TOMCAT_RAM=6G
    export TOMCAT_THREADS=1000
;;
'm1.xlarge' )
    export TOMCAT_RAM=12G
    export TOMCAT_THREADS=2000
;;
'm3.xlarge' )
    export TOMCAT_RAM=12G
    export TOMCAT_THREADS=3300
;;
'm3.large' )
    export TOMCAT_RAM=6G
    export TOMCAT_THREADS=1600
;;
'c3.2xlarge' )
    export TOMCAT_RAM=12G
    export TOMCAT_THREADS=2000
;;
'c3.4xlarge' )
    export TOMCAT_RAM=24G
    export TOMCAT_THREADS=4000
esac

export TOMCAT_CONNECTIONS=10000
sed -i.bak "s/Xmx128m/Xmx${TOMCAT_RAM} -Xms${TOMCAT_RAM} -Dlog4j\.configuration=file:\/usr\/share\/usergrid\/lib\/log4j\.properties/g" /etc/default/tomcat7
sed -i.bak "s/<Connector/<Connector maxThreads=\"${TOMCAT_THREADS}\" acceptCount=\"${TOMCAT_THREADS}\" maxConnections=\"${TOMCAT_CONNECTIONS}\"/g" /var/lib/tomcat7/conf/server.xml

# set file limits
sed -i.bak "s/# \/etc\/init\.d\/tomcat7 -- startup script for the Tomcat 6 servlet engine/ulimit -n ${NOFILE}/" /etc/init.d/tomcat7
sed -i.bak "s/@student/a *\t\thard\tnofile\t\t${NOFILE}\n*\t\tsoft\tnofile\t\t${NOFILE}" /etc/security/limits.conf
echo "$NOFILE" | sudo tee > /proc/sys/fs/nr_open
echo "$NOFILE" | sudo tee > /proc/sys/fs/file-max
cat >> /etc/pam.d/su << EOF
session    required   pam_limits.so
EOF
ulimit -n $NOFILE

# increase system IP port limits (do we really need this for Tomcat?)
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_local_port_range = 1024 65535
EOF

# wait for enough Cassandra nodes then delpoy and configure Usergrid 
cd /usr/share/usergrid/scripts
groovy wait_for_instances.groovy cassandra ${CASSANDRA_NUM_SERVERS}
groovy wait_for_instances.groovy graphite ${GRAPHITE_NUM_SERVERS}

# link WAR and Portal into Tomcat's webapps dir
rm -rf /var/lib/tomcat7/webapps/*
ln -s /usr/share/usergrid/webapps/ROOT.war /var/lib/tomcat7/webapps/ROOT.war
ln -s /usr/share/usergrid/webapps/portal /var/lib/tomcat7/webapps/portal
chown -R tomcat7 /usr/share/usergrid/webapps
chown -R tomcat7 /var/lib/tomcat7/webapps

# configure usergrid
mkdir -p /usr/share/tomcat7/lib 
groovy configure_usergrid.groovy > /usr/share/tomcat7/lib/usergrid-custom.properties 
# create a copy for 1.0 too
cp /usr/share/tomcat7/lib/usergrid-custom.properties /usr/share/tomcat7/lib/usergrid-deployment.properties  
groovy configure_portal_new.groovy >> /var/lib/tomcat7/webapps/portal/config.js

# Go
sh /etc/init.d/tomcat7 start

# tag last so we can see in the console that the script ran to completion
cd /usr/share/usergrid/scripts
groovy tag_instance.groovy