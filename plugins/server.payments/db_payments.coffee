# oauthd
# http://oauth.io
#
# Copyright (c) 2013 thyb, bump
# For private use only.
#
# Paymill NodeJS docs : https://github.com/komola/paymill-node
#

async = require 'async'
Mailer = require '../../lib/mailer'
{ db, check, config } = shared = require '../shared'
paymill = require('paymill-node')(config.paymill.secret_key)

exports.process = (data, client, callback) ->

	client_id = client.id
	client_email = client.mail
	isNewUser = false

	client_obj =
		email : ''

	payment_obj =
		token: ''
		client: ''

	subscription_obj =
		client: ''
		offer: ''
		payment: ''

	subscriptions_root_prefix = "pm:subscriptions"
	payments_root_prefix = "pm:payments"

	async.series [

		# create Paymill user
		(cb) ->
			console.log "creating Paymill user..."
			db.redis.hget ["#{subscriptions_root_prefix}", client_id], (err, current_id) ->
				return cb err if err

				client_obj.id = current_id if current_id?
				client_obj.email = client_email

				if not current_id?

					console.log "\t new user detected"

					isNewUser = true
					console.log "\t creating on redis..."
					# create Paymill user
					paymill.clients.create client_obj, (err, client) ->
						return cb err if err

						id = client.data.id # Paymill id
						client_obj.id = id

						# Paymill user id to Redis
						db.redis.hset "#{subscriptions_root_prefix}", client_id, id, (err, res) ->
							return cb err if err
							console.log "\t [OK]"
							cb()
				else
					console.log "\t user exists with id #{current_id}"
					cb()

		# create payment
		(cb) ->

			payment_obj.token = data.token
			payment_obj.client = client_obj.id

			if isNewUser
				console.log "creating Paymill payment...(card info)"

				paymill.payments.create payment_obj, (err, payment) ->

					console.log err
					return cb err if err

					payment_obj.id = payment.data.id

					console.log "\t creating on redis..."

					# Payment : credit card infos...
					payment_prefix = "#{payments_root_prefix}:#{client_id}:#{payment.data.id}"

					db.redis.multi([

						[ "hset", "#{payments_root_prefix}:#{client_id}", "current", payment_obj.id ],

						[ "mset", "#{payment_prefix}:client", payment.data.client,
						"#{payment_prefix}:card_type", payment.data.card_type,
						"#{payment_prefix}:country", payment.data.country,
						"#{payment_prefix}:expire_month", payment.data.expire_month,
						"#{payment_prefix}:expire_year", payment.data.expire_year,
						"#{payment_prefix}:card_holder", payment.data.card_holder,
						"#{payment_prefix}:last4", payment.data.last4,
						"#{payment_prefix}:created_at", payment.data.created_at ]

					]).exec (err) ->
						return cb err if err
						cb()
			else
				console.log "retrieving credit card informations..."

				# get current payment
				db.redis.mget ["#{payments_root_prefix}", "current"], (err, res) ->
					return cb err if err
					payment_obj.id = res
					cb()


		# create subscription
		(cb) ->

			if data.offer # it's a subscription to an offer

				subscription_obj.client = client_obj.id
				subscription_obj.offer = data.offer
				subscription_obj.payment = payment_obj.id

				if isNewUser
					console.log "creating Paymill subscription..."

					paymill.subscriptions.create subscription_obj, (err, subscription) ->
						return cb err if err

						console.log "\t subscription created on Paymill"
						console.log "\t creating on redis..."

						subscription_prefix = "#{subscriptions_root_prefix}:#{client_id}:#{subscription.data.id}"

						db.redis.multi([

							[ "hset", "#{subscriptions_root_prefix}:#{client_id}", "current_subscription", subscription.data.id ],

							[ "hset", "#{subscriptions_root_prefix}:#{client_id}", "current_offer", subscription_obj.offer ],

							[ "mset", "#{subscription_prefix}:id", subscription.data.id,
								"#{subscription_prefix}:offer", subscription.data.offer.id,
								"#{subscription_prefix}:next_capture_at", subscription.data.next_capture_at,
								"#{subscription_prefix}:created_at", subscription.data.created_at,
								"#{subscription_prefix}:updated_at", subscription.data.updated_at,
								"#{subscription_prefix}:canceled_at", subscription.data.canceled_at,
								"#{subscription_prefix}:payment", subscription.data.payment.id,
								"#{subscription_prefix}:client", subscription.data.client.id,
								"#{subscription_prefix}:notified", false ]

						]).exec (err, res) ->
							return cb err if err
							console.log "\t subscription created on Redis"
							cb()
				else
					console.log "update Paymill subscription..."

					db.redis.multi([

						[ "hget", "#{subscriptions_root_prefix}:#{client_id}", "current_subscription"],

						[ "hget", "#{subscriptions_root_prefix}:#{client_id}", "current_offer" ]

					]).exec (err, res) ->
						return cb err if err
						return cb new check.Error "An error occured, please contact support@oauth.io" if not res?
						console.log res[1], subscription_obj.offer
						return cb new check.Error "You can not subscribe to the same plan" if res[1] == subscription_obj.offer

						update_subscription_obj =
							cancel_at_period_end : false
							offer : subscription_obj.offer

						paymill.subscriptions.update res[0], update_subscription_obj, (err, subscription_updated) ->
							return cb err if err

							db.redis.hset ["#{subscriptions_root_prefix}:#{client_id}", "current_offer", subscription_updated.data.id ], (err, res) ->
								return cb err if err
								cb()
			else
				cb new check.Error "Missing offer !"

		# notify user
		(cb) ->
			console.log "notified user not yet implemented !"
			console.log "BUT EVERYTHING IS OK ;-)"
			cb()

	], (err, result) ->
		return callback err if err
		return callback null, result

exports.update = (offer_id, callback) ->
	console.log("UPDATE");

# create an Offer
exports.createOffer = (amount, name, currency, interval, status, callback) ->

	console.log("create Offer "+ name + " of " + amount + " " + currency + " during " + interval + " in " + status);
	prefix = "pm:offers"

	db.redis.sismember [ "#{prefix}:#{name}", 1 ], (err, res) ->
		return callback err if err
		return callback new check.Error "Sorry but you have already added " + name.toUpperCase() if res == 1

		paymill.offers.create
			amount: amount
			currency: currency
			interval: interval
			name: name
		,(err, offer) ->
			return callback err if err

			console.log "offer id " + offer.data.id

			offer.data.name = name;
			offer.data.status = status;

			db.redis.multi([
				[ 'sadd', "#{prefix}", name ],
				[ 'sadd', "#{prefix}:#{name}", 1],
				[ 'mset', "#{prefix}:#{name}:id", offer.data.id,
						"#{prefix}:#{name}:currency", offer.data.currency,
						"#{prefix}:#{name}:interval", offer.data.interval,
						"#{prefix}:#{name}:created_at", offer.data.created_at,
						"#{prefix}:#{name}:updated_at", offer.data.updated_at,
						"#{prefix}:#{name}:amount", offer.data.amount,
						"#{prefix}:#{name}:status", status,					  	"#{prefix}:#{name}:subscription_count:active", offer.data.subscription_count.active,
					  	"#{prefix}:#{name}:subscription_count:inactive", offer.data.subscription_count.inactive
				 ]
				[ 'sadd', "#{prefix}:#{status}", name ],
				[ 'mset', "#{prefix}:#{status}:#{name}:id", offer.data.id,
						"#{prefix}:#{status}:#{name}:amount", offer.data.amount,
						"#{prefix}:#{status}:#{name}:interval", offer.data.interval
				 ]
				]).exec (err) ->
					return callback err if err
					return callback null, offer.data

# delete an Offer
exports.removeOffer = (name, callback) ->
	prefix = 'pm:offers:' + name
	db.redis.sismember ['pm:offers' , name], (err, res) ->
		return callback err if err

		db.redis.multi([
			[ 'get', "#{prefix}:id"], 
			[ 'get', "#{prefix}:status"],
		]).exec (err, replies) ->
			return callback err if err
			
			id_offer = replies[0]

			paymill.offers.remove id_offer, (err, offer) ->
  				return callback err if err

			prefix2 = 'pm:offers:' + replies[1]
			prefix3 = prefix2 + ':' + name

			db.redis.multi([
				[ 'del', prefix+':id', prefix+':currency', prefix+':interval',prefix+':created_at',prefix+':updated_at',prefix+':amount', prefix+':subscription_count:active',prefix+':subscription_count:inactive',prefix+':status',prefix, prefix3+':id', prefix3+':currency', prefix3+':amount',prefix3+':interval', prefix3]
				[ 'srem', 'pm:offers', name],
				[ 'srem', prefix2, name],
			]).exec (err, replies) ->
				return callback err if err
				return callback null, name

# getList of Offer
exports.getOffersList = (callback) ->

	prefix = "pm:offers"

	db.redis.smembers "#{prefix}", (err, offers) ->
		return callback err if err
		return callback null, [] if not offers.length

		cmds = []
		tmpName = []
		j = 0;
		for p in offers
			tmpName[j++] = p
			cmds.push [ "get", "#{prefix}:#{p}:id"]
			cmds.push [ "get", "#{prefix}:#{p}:currency"]
			cmds.push [ "get", "#{prefix}:#{p}:interval"]
			cmds.push [ "get", "#{prefix}:#{p}:created_at"]
			cmds.push [ "get", "#{prefix}:#{p}:updated_at"]
			cmds.push [ "get", "#{prefix}:#{p}:amount"]
			cmds.push [ "get", "#{prefix}:#{p}:status"]
			cmds.push [ "get", "#{prefix}:#{p}:subscription_count:active"]
			cmds.push [ "get", "#{prefix}:#{p}:subscription_count:inactive"]

		db.redis.multi(cmds).exec (err, res) ->
			return callback err if err

			for i of offers
				offers[i] = id:res[i * 9], currency:res[i * 9 + 1], interval:res[i * 9 + 2], created_at:res[i * 9 + 3], updated_at:res[i * 9 + 4], amount:res[i * 9 + 5], status:res[i * 9 + 6], subscription_count:active:res[i * 9 + 7], subscription_count:inactive:res[i * 9 + 8]
				offers[i].name = tmpName[i]

			return callback null, offers

# update Status of an Offer
exports.updateStatus = (name, currentStatus, callback) ->

	newStatus = "private"
	if currentStatus == "private"
		newStatus = "public"

	prefix = "pm:offers:" + name 
	prefixStatus = "pm:offers:" + currentStatus + ":" + name
	prefixNewStatus = "pm:offers:" + newStatus
	db.redis.multi([
		[ 'get', "#{prefix}:id"], 
		[ 'get', "#{prefix}:amount"],
		[ 'get', "#{prefix}:interval"],
	]).exec (err, replies) ->
		return callback err if err

		offer = {}
		offer.id = replies[0]
		offer.amount = replies[1]
		offer.interval = replies[2]

		db.redis.multi([
			[ 'del', "#{prefixStatus}:id", prefixStatus+':interval', prefixStatus+':amount', prefixStatus]
			[ 'set', "#{prefix}:status", newStatus],
			[ 'sadd', "#{prefixNewStatus}", name ],
			[ 'mset', "#{prefixNewStatus}:#{name}:id", offer.id,
					"#{prefixNewStatus}:#{name}:amount", offer.amount,
					"#{prefixNewStatus}:#{name}:interval", offer.interval
			]
		]).exec (err, replies) ->
			return callback err if err
			return callback null, name


# update an Offer
#exports.updateOffer = (amount, name, currency, interval, callback) ->
#
#	console.log("update Offer "+ name + " of " + amount + " " + currency + " during " + interval);
#	prefix = "pm:offers"
#
#	db.redis.sismember [ "#{prefix}:#{name}", 1 ], (err, res) ->
#		return callback err if err
#		return callback new check.Error "Sorry but you have already added " + name.toUpperCase() if res == 1
#
#		paymill.offers.update
#			amount: amount
#			currency: currency
#			interval: interval
#			name: name
#		,(err, offer) ->
#			return callback err if err
#
#			console.log "offer id " + offer.data.id
#
#			offer.data.name = name;
#			console.log "offer name " + offer.data.name
#
#			db.redis.multi([
#				[ 'sadd', "#{prefix}", name ],
#				[ 'sadd', "#{prefix}:#{name}", 1],
#				[ 'mset', "#{prefix}:#{name}:id", offer.data.id,
#						"#{prefix}:#{name}:currency", offer.data.currency,
#						"#{prefix}:#{name}:interval", offer.data.interval,
#						"#{prefix}:#{name}:created_at", offer.data.created_at,
#						"#{prefix}:#{name}:updated_at", offer.data.updated_at,
#						"#{prefix}:#{name}:amount", offer.data.amount,
#					  	"#{prefix}:#{name}:subscription_count:active", offer.data.subscription_count.active,
#					  	"#{prefix}:#{name}:subscription_count:inactive", offer.data.subscription_count.inactive
#				 ]
#				]).exec (err) ->
#					return callback err if err
#					return callback null, offer.data
