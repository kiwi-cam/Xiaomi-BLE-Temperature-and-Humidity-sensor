#!/bin/bash

#mqtt_topic="mi_temp"
#mqtt_ip="127.0.0.1"

sensors_file="/usr/lib/mi_temp/sensors"

cel=$'\xe2\x84\x83'
per="%"

red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
nc='\033[0m'

script_name="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"

lock_file="/var/tmp/$script_name"
if [ -e "${lock_file}" ] && kill -0 "$(cat "${lock_file}")"; then
    exit 99
fi

trap 'rm -f "${lock_file}"; exit' INT TERM EXIT
echo $$ > "${lock_file}"

echo "Opening and initializing HCI device"
sudo hciconfig hci0 up
echo "Enabling LE Mode"
sudo btmgmt le on

while read -r item; do
    sensor=(${item//,/ })
    mac="${sensor[0]}"
    name="${sensor[1]}"
    outputFile="${sensor[2]}"
    echo -e "\n${yellow}Sensor: $name ($mac)${nc}"
    unset data
    counter="0"

    until [ -n "$data" ] || [ "$counter" -ge 5 ] ; do
        counter=$((counter+1))
        echo -n "  Getting $name Temperature and Humidity... "
        data=$(timeout 15 /usr/bin/gatttool -b "$mac" --char-write-req --handle=0x0038 -n 0100 --listen 2>&1 | grep -m 1 "Notification handle")
        if [ -z "$data" ]; then
            echo -e "${red}failed, waiting 5 seconds before trying again${nc}"
            sleep 5
        else
            echo -e "${green}success${nc}"
        fi
    done

    temphexa=$(echo $data | awk -F ' ' '{print $7$6}'| tr [:lower:] [:upper:] )
    temp=$(echo "ibase=16; $temphexa" | bc)
    temp=$(echo "scale=2;$temp/100" | bc)
    humhexa=$(echo $data | awk -F ' ' '{print $8}'| tr [:lower:] [:upper:])
    humid=$(echo "ibase=16; $humhexa" | bc)
    dewp=$(echo "scale=1; (243.12 * (l( $humid / 100) +17.62* $temp/(243.12 + $temp)) / 17.62 - (l( $humid / 100) +17.62* $temp/(243.12 + $temp))  )" | bc -l)
    battery=$(echo $data | awk -F ' ' '{print $10$9}'| tr [:lower:] [:upper:] )
    batteryV=$(echo "ibase=16; $battery" | bc)
    batteryV=$(echo "scale=2;$batteryV/1000" | bc)
    batt=$(echo "($batteryV-2.1)*100" | bc)
    echo "  Temperature: $temp$cel"
    echo "  Humidity: $humid$per"
    echo "  Battery Voltage: $batteryV V"
    echo "  Battery Level: $batt$per"
    echo "  Dew Point: $dewp$cel"


    if [ -n "$outputFile" ]; then
      echo -e -n "  Publishing data to $outputFile... "
      if grep -q "time:" $outputFile; then
        sed -i "/time/s/:.*/:$(date)/" "$outputFile"
      else
        echo "time:$(date)" >> "$outputFile"
      fi
      if [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if grep -q "temperature:" $outputFile; then
                sed -i "/temperature/s/:.*/:$temp/" "$outputFile"
        else
                echo "temperature:$temp" >> "$outputFile"
        fi
      fi

      if [[ "$humid" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if grep -q "humidity:" $outputFile; then
                sed -i "/humidity/s/:.*/:$humid/" "$outputFile"
        else
                echo "humidity:$humid" >> "$outputFile"
        fi
      fi

      if [[ "$batt" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if grep -q "battery:" $outputFile; then
                sed -i "/battery/s/:.*/:$batt/" "$outputFile"
        else
                echo "battery:$batt" >> "$outputFile"
        fi
      fi

      if [[ "$dewp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if grep -q "dewpt:" $outputFile; then
                sed -i "/dewpt/s/:.*/:$dewp/" "$outputFile"
        else
                echo "dewpt:$dewp" >> "$outputFile"
        fi
      fi
    fi
    
    if [ -n "$mqtt_topic" ]; then
      echo -e -n "  Publishing data via MQTT... "
      if [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        /usr/bin/mosquitto_pub -h $mqtt_ip -V mqttv311 -t "/$mqtt_topic/$name/temperature" -m "$temp"
      fi

      if [[ "$humid" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        /usr/bin/mosquitto_pub -h $mqtt_ip -V mqttv311 -t "/$mqtt_topic/$name/humidity" -m "$humid"
      fi

      if [[ "$batt" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        /usr/bin/mosquitto_pub -h $mqtt_ip -V mqttv311 -t "/$mqtt_topic/$name/battery" -m "$batt"
      fi
    
      if [[ "$dewp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        /usr/bin/mosquitto_pub -h $mqtt_ip -V mqttv311 -t "/$mqtt_topic/$name/dewpoint" -m "$dewp"
      fi
    fi
    
    echo -e "done"
done < "$sensors_file"

echo -e "\nclosing HCI device"
sudo hciconfig hci0 down

echo "Finished"
