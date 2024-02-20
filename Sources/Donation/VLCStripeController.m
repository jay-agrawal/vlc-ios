/*****************************************************************************
 * VLCStripeController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2024 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCStripeController.h"
#import <PassKit/PassKit.h>
#import <AFNetworking/AFNetworking.h>
#import "VLCCurrency.h"

const NSString *publishableStripeAPIKey = @"";
const NSString *secretStripeAPIKey = @"";
NSString *callbackURLString = @"vlcpay://3ds";

@interface VLCStripeController()
{
    VLCCurrency *_currency;
    NSString *_amount;

    NSDictionary *_card;
    NSString *_tokenID;
}
@end

@implementation VLCStripeController

#pragma mark - apple pay internals

- (void)processPayment:(PKPayment *)payment forAmount:(NSNumber *)amount currency:(VLCCurrency *)currency
{
    _currency = currency;
    _amount = [[NSNumber numberWithInt:amount.intValue * 100] stringValue];

    NSDictionary *parameters = [self constructParametersForPayment:payment];
    [self createStripeTokenWithParameters:parameters];
}

- (NSDictionary *)constructParametersForPayment:(PKPayment *)payment
{
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionary];
    mutDict[@"pk_token"] = [[NSString alloc] initWithData:payment.token.paymentData encoding:NSUTF8StringEncoding];

    PKContact *contact = payment.billingContact;
    if (contact) {
        NSMutableDictionary *cardMutDict = [NSMutableDictionary dictionary];
        NSPersonNameComponents *name = contact.name;
        if (name) {
            cardMutDict[@"name"] = [NSPersonNameComponentsFormatter localizedStringFromPersonNameComponents:name style:NSPersonNameComponentsFormatterStyleDefault options:0];
        }

        NSString *email = contact.emailAddress;
        if (email) {
            cardMutDict[@"email"] = email;
        }

        CNPhoneNumber *phoneNumber = contact.phoneNumber;
        if (phoneNumber) {
            cardMutDict[@"phone"] = phoneNumber.stringValue ? phoneNumber.stringValue : [NSNull null];
        }

        CNPostalAddress *address = contact.postalAddress;
        if (address) {
            cardMutDict[@"address_line1"] = address.street ? address.street : [NSNull null];
            cardMutDict[@"address_city"] = address.city ? address.city : [NSNull null];
            cardMutDict[@"address_state"] = address.state ? address.state : [NSNull null];
            cardMutDict[@"address_zip"] = address.postalCode ? address.postalCode : [NSNull null];
            cardMutDict[@"address_country"] = address.ISOCountryCode ?  address.ISOCountryCode.uppercaseString : [NSNull null];
        }

        mutDict[@"card"] = [cardMutDict copy];
    }

    mutDict[@"pk_token_instrument_name"] = payment.token.paymentMethod.displayName;
    mutDict[@"pk_token_payment_network"] = payment.token.paymentMethod.network;

    if ([payment.token.transactionIdentifier isEqualToString:@"Simulated Identifier"]) {
        /* use a fake ID */
        mutDict[@"pk_token_transaction_id"] = [NSString stringWithFormat:@"ApplePayStubs~4242424242424242~0~USD~%@", [[NSUUID UUID] UUIDString]];
    } else {
        mutDict[@"pk_token_transaction_id"] = payment.token.transactionIdentifier ? payment.token.transactionIdentifier : [NSNull null];
    }

    return [mutDict copy];
}

#pragma mark - CB internals

- (void)processPaymentWithCard:(NSString *)cardNumber cvv:(NSString *)cvv exprMonth:(NSString *)month exprYear:(NSString *)year forAmount:(NSNumber *)amount currency:(VLCCurrency *)currency
{
    _currency = currency;
    _amount = [[NSNumber numberWithInt:amount.intValue * 100] stringValue];

    NSMutableDictionary *mutDict = [NSMutableDictionary dictionary];
    mutDict[@"card[number]"] = cardNumber;
    mutDict[@"card[exp_month]"] = month;
    mutDict[@"card[exp_year]"] = year;
    mutDict[@"card[cvc]"] = cvv;

    [self createStripeTokenWithParameters:[mutDict copy]];
}

#pragma mark - generic API

- (void)createStripeTokenWithParameters:(NSDictionary *)parameters
{
    // Construct the request URL and headers
    NSString *urlString = @"https://api.stripe.com/v1/tokens";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", publishableStripeAPIKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    // Construct the request body
    NSString *bodyString = AFQueryStringFromParameters(parameters);
    NSData *bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    [request setHTTPBody:bodyData];

    // Perform the request
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Handle error
            APLog(@"Error creating Stripe token: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:error.localizedDescription];
            });
        } else {
            // Handle success
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            self->_tokenID = jsonResponse[@"id"];
            if (self->_tokenID) {
                APLog(@"Stripe token created successfully");
                self->_card = jsonResponse[@"card"];
                // a CVC check is not needed
                if (self->_card[@"cvc_check"] == nil) {
                    [self processPayment];
                } else {
                    [self confirmPaymentIntent];
                }
            } else {
                APLog(@"Error creating Stripe token: %@", jsonResponse);
                NSDictionary *errorDict = jsonResponse[@"error"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate stripeProcessingFailedWithError:errorDict ? errorDict[@"message"] : @"unknown"];
                });
            }
        }
    }] resume];
}

- (void)processPayment {
    // Construct the request URL and headers
    NSString *urlString = @"https://api.stripe.com/v1/charges";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", secretStripeAPIKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    // Construct the request body
    NSString *bodyString = [NSString stringWithFormat:@"amount=%@&currency=%@&source=%@", _amount, _currency.isoCode, _tokenID];
    NSData *bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    [request setHTTPBody:bodyData];

    // Perform the request
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Handle error
            APLog(@"Error processing payment: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:error.localizedDescription];
            });
        } else {
            // Handle success
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *receipt = jsonResponse[@"receipt_url"];
            if ([jsonResponse[@"paid"] boolValue]) {
                APLog(@"Payment successfully processed");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate stripeProcessingSucceededWithReceipt:receipt];
                });
            } else {
                NSDictionary *errorDict = jsonResponse[@"error"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate stripeProcessingFailedWithError:errorDict ? errorDict[@"message"] : @"unknown"];
                });
                APLog(@"Received negative response from Stripe: %@", jsonResponse);
            }
        }
    }] resume];
}

- (void)confirmPaymentIntent
{
    // Construct the request URL and headers
    NSString *urlString = @"https://api.stripe.com/v1/payment_intents";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", secretStripeAPIKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    // Construct the request body
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionary];
    mutDict[@"confirm"] = @"true";
    mutDict[@"amount"] = _amount;
    mutDict[@"currency"] = _currency.isoCode;
    mutDict[@"payment_method_data"] = @{ @"type" : @"card", @"card[token]" : _tokenID };
    mutDict[@"return_url"] = callbackURLString;

    NSString *bodyString = AFQueryStringFromParameters(mutDict);
    NSData *bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    [request setHTTPBody:bodyData];

    // Perform the request
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Handle error
            APLog(@"Error processing payment: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:error.localizedDescription];
            });
        } else {
            // Handle success
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *nextAction = jsonResponse[@"next_action"];
            int amountReceived = [jsonResponse[@"amount_received"] intValue];
            NSString *chargeID = jsonResponse[@"latest_charge"];

            if (nextAction != nil && nextAction != [NSNull null]) {
                NSDictionary *redirectToURL = nextAction[@"redirect_to_url"];
                NSString *url = redirectToURL[@"url"];
                NSURL *redirectURL = [NSURL URLWithString:url];
                if (redirectURL != nil) {
                    if ([self.delegate respondsToSelector:@selector(show3DS:withCallbackURL:)]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.delegate show3DS:(NSURL *)redirectURL withCallbackURL:[NSURL URLWithString:callbackURLString]];
                        });
                        return;
                    }
                }
            } else {
                if (amountReceived > 0) {
                    [self requestCharge:chargeID];
                    return;
                }
            }

            NSDictionary *errorDict = jsonResponse[@"error"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:errorDict ? errorDict[@"message"] : @"unknown"];
            });
            APLog(@"Received negative response from Stripe: %@", jsonResponse);
        }
    }] resume];
}

- (void)continueWithPaymentIntent:(NSString *)paymentIntent
{
    // Construct the request URL and headers
    NSString *urlString = [NSString stringWithFormat:@"https://api.stripe.com/v1/payment_intents/%@", paymentIntent];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", secretStripeAPIKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:nil];

    // Perform the request
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Handle error
            APLog(@"Error processing payment: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:error.localizedDescription];
            });
        } else {
            // Handle success
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            int amountReceived = [jsonResponse[@"amount_received"] intValue];
            NSString *chargeID = jsonResponse[@"latest_charge"];
            if (amountReceived != 0) {
                [self requestCharge:chargeID];
                return;
            }

            NSDictionary *errorDict = jsonResponse[@"error"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:errorDict ? errorDict[@"message"] : @"Card rejected"];
            });
            APLog(@"Received negative response from Stripe: %@", jsonResponse);
        }
    }] resume];
}

- (void)requestCharge:(NSString *)chargeID
{
    // Construct the request URL and headers
    NSString *urlString = [NSString stringWithFormat:@"https://api.stripe.com/v1/charges/%@", chargeID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", secretStripeAPIKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:nil];

    // Perform the request
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Handle error
            APLog(@"Error requesting charge: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:error.localizedDescription];
            });
        } else {
            // Handle success
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *receiptURLString = jsonResponse[@"receipt_url"];
            BOOL captured = [jsonResponse[@"captured"] boolValue];

            if (captured) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate stripeProcessingSucceededWithReceipt:receiptURLString];
                });
                return;
            }

            NSDictionary *errorDict = jsonResponse[@"error"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate stripeProcessingFailedWithError:errorDict ? errorDict[@"message"] : @"Card rejected"];
            });
            APLog(@"Received negative response from Stripe: %@", jsonResponse);
        }
    }] resume];
}

@end
