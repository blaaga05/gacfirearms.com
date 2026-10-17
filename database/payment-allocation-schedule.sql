select cron.schedule('gac-payment-expiry','30 seconds','select gac_private.invoke_payment_expiry()');
