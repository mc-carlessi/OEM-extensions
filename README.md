# OEM-extensions
Here samples for scripts to extend Mysql Enterprise monitoring provided by Oracle Enterprise Manager 24ai with metric extensions.
These scripts are provided for illustrative purposes only and should not be considered as an official recommendation from Oracle.
Thank you to AI that helped me to write them.

The script mysql_router_status.pl is a perl sample that
* retrieves router list from MySQL InnoDB Cluster metadata 
* query Router REST API to check the status of all the routers
* print out a table summary per each rotuer with router id, router address, router port, router status, router version, router uptime  

