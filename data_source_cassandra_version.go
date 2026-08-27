package main

import (
	"log"
	"time"

	"github.com/gocql/gocql"
	"github.com/hashicorp/terraform-plugin-sdk/helper/schema"
)

func dataSourceCassandraVersion() *schema.Resource {
	return &schema.Resource{
		Read: dataSourceCassandraVersionRead,
		Schema: map[string]*schema.Schema{
			"version": &schema.Schema{
				Type:        schema.TypeString,
				Computed:    true,
				Description: "release_version reported by system.local on the node Terraform connects to",
			},
		},
	}
}

func dataSourceCassandraVersionRead(d *schema.ResourceData, meta interface{}) error {
	cluster := meta.(*gocql.ClusterConfig)

	start := time.Now()

	session, sessionCreateError := cluster.CreateSession()

	elapsed := time.Since(start)

	log.Printf("Getting a session took %s", elapsed)

	if sessionCreateError != nil {
		return sessionCreateError
	}

	defer session.Close()

	var version string

	if err := session.Query(`SELECT release_version FROM system.local`).Scan(&version); err != nil {
		return err
	}

	d.Set("version", version)
	d.SetId("cassandra_version")

	return nil
}
