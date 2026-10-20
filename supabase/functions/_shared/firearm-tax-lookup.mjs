const STATES = new Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC".split(" "));

export function normalizeFirearmTaxLookup(input) {
  const clean = (value, max) => typeof value === "string" ? value.trim().slice(0, max) : "";
  const destination = {
    line1: clean(input?.line1, 128),
    line2: clean(input?.line2, 128),
    city: clean(input?.city, 64),
    state: clean(input?.state, 2).toUpperCase(),
    zip: clean(input?.zip, 20),
  };
  const firearmPriceCents = input?.firearmPriceCents;
  const shippingCents = input?.shippingCents;
  if (destination.line1.length < 2 || destination.city.length < 2 ||
      !STATES.has(destination.state) || !/^\d{5}(?:-\d{4})?$/.test(destination.zip)) {
    throw new Error("Enter the receiving FFL’s street address, city, state, and ZIP code.");
  }
  if (!Number.isInteger(firearmPriceCents) || firearmPriceCents < 1 || firearmPriceCents > 100000000 ||
      !Number.isInteger(shippingCents) || shippingCents < 0 || shippingCents > 1000000) {
    throw new Error("The firearm price or shipping amount is invalid.");
  }
  return { destination, firearmPriceCents, shippingCents };
}

export function taxCloudCartPayload({ destination, origin, firearmPriceCents, shippingCents, cartId }) {
  const address = value => ({
    line1: value.line1,
    ...(value.line2 ? { line2: value.line2 } : {}),
    city: value.city,
    state: value.state,
    zip: value.zip,
    countryCode: "US",
  });
  const lineItems = [{ index: 0, itemId: "firearm", price: firearmPriceCents / 100, quantity: 1, tic: 0 }];
  if (shippingCents > 0) lineItems.push({ index: 1, itemId: "shipping", price: shippingCents / 100, quantity: 1, tic: 11010 });
  return {
    items: [{
      cartId,
      currency: { currencyCode: "USD" },
      customerId: "gac-firearm-checkout",
      destination: address(destination),
      origin: address(origin),
      lineItems,
    }],
  };
}

export function normalizeTaxCloudQuote(response) {
  const cart = response?.items?.[0];
  const lines = cart?.lineItems;
  if (!Array.isArray(lines) || !lines.length || lines.some(line => !Number.isFinite(line?.tax?.amount))) {
    throw new Error("The tax service returned an incomplete estimate. Check the address and TaxCloud account setup.");
  }
  const cents = value => Math.round(value * 100);
  const firearmLine = lines.find(line => line.itemId === "firearm") || lines[0];
  const shippingLine = lines.find(line => line.itemId === "shipping");
  const totalTaxCents = lines.reduce((total, line) => total + cents(line.tax.amount), 0);
  return {
    destination: {
      city: cart.destination?.city || "",
      state: cart.destination?.state || "",
      zip: cart.destination?.zip || "",
    },
    rate: Number.isFinite(firearmLine.tax?.rate) ? firearmLine.tax.rate : null,
    firearmTaxCents: cents(firearmLine.tax.amount),
    shippingTaxCents: shippingLine ? cents(shippingLine.tax.amount) : 0,
    totalTaxCents,
    cartId: cart.cartId || null,
  };
}
