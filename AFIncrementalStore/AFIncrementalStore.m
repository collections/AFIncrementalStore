// AFIncrementalStore.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFIncrementalStore.h"
#import "AFHTTPClient.h"
#import <objc/runtime.h>

NSString * const AFIncrementalStoreUnimplementedMethodException = @"com.alamofire.incremental-store.exceptions.unimplemented-method";

NSString * const AFIncrementalStoreContextWillFetchRemoteValues = @"AFIncrementalStoreContextWillFetchRemoteValues";
NSString * const AFIncrementalStoreContextWillSaveRemoteValues = @"AFIncrementalStoreContextWillSaveRemoteValues";
NSString * const AFIncrementalStoreContextDidFetchRemoteValues = @"AFIncrementalStoreContextDidFetchRemoteValues";
NSString * const AFIncrementalStoreContextDidSaveRemoteValues = @"AFIncrementalStoreContextDidSaveRemoteValues";
NSString * const AFIncrementalStoreRequestOperationKey = @"AFIncrementalStoreRequestOperation";
NSString * const AFIncrementalStorePersistentStoreRequestKey = @"AFIncrementalStorePersistentStoreRequest";
NSString * const AFIncrementalStoreFetchedObjectsKey = @"AFIncrementalStoreFetchedObjectsKey";

static char kAFResourceIdentifierObjectKey;

static NSString * const kAFIncrementalStoreResourceIdentifierAttributeName = @"__af_resourceIdentifier";
static NSString * const kAFIncrementalStoreLastModifiedAttributeName = @"__af_lastModified";

static NSString * const kAFReferenceObjectPrefix = @"__af_";

inline NSString * AFReferenceObjectFromResourceIdentifier(NSString *resourceIdentifier) {
    if (!resourceIdentifier) {
        return nil;
    }
    
    return [kAFReferenceObjectPrefix stringByAppendingString:resourceIdentifier];    
}

inline NSString * AFResourceIdentifierFromReferenceObject(id referenceObject) {
    if (!referenceObject) {
        return nil;
    }
    
    NSString *string = [referenceObject description];
    return [string hasPrefix:kAFReferenceObjectPrefix] ? [string substringFromIndex:[kAFReferenceObjectPrefix length]] : string;
}

static int AFDelta = 2;

@interface NSManagedObject (_AFIncrementalStore)
@property (readwrite, nonatomic, copy, setter = af_setResourceIdentifier:) NSString *af_resourceIdentifier;
@end

@implementation NSManagedObject (_AFIncrementalStore)
@dynamic af_resourceIdentifier;

- (NSString *)af_resourceIdentifier {
    NSString *identifier = (NSString *)objc_getAssociatedObject(self, &kAFResourceIdentifierObjectKey);
    
    if (!identifier) {
        if ([self.objectID.persistentStore isKindOfClass:[AFIncrementalStore class]]) {
            id referenceObject = [(AFIncrementalStore *)self.objectID.persistentStore referenceObjectForObjectID:self.objectID];
            if ([referenceObject isKindOfClass:[NSString class]]) {
                return AFResourceIdentifierFromReferenceObject(referenceObject);
            }
        }
    }
    
    return identifier;
}

- (void)af_setResourceIdentifier:(NSString *)resourceIdentifier {
    objc_setAssociatedObject(self, &kAFResourceIdentifierObjectKey, resourceIdentifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@end

#pragma mark -

@implementation AFIncrementalStore {
@private
    NSCache *_backingObjectIDByObjectID;
    NSMutableDictionary *_registeredObjectIDsByEntityNameAndNestedResourceIdentifier;
    NSPersistentStoreCoordinator *_backingPersistentStoreCoordinator;
    NSManagedObjectContext *_backingManagedObjectContext;
    NSMutableSet *_refreshingRelationships;
    NSMutableSet *_refreshingObjects;
}
@synthesize HTTPClient = _HTTPClient;
@synthesize backingPersistentStoreCoordinator = _backingPersistentStoreCoordinator;

+ (NSString *)type {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +type. Must be overridden in a subclass", nil) userInfo:nil]);
}

+ (NSManagedObjectModel *)model {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +model. Must be overridden in a subclass", nil) userInfo:nil]);
}

#pragma mark -

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
             aboutRequestOperation:(AFHTTPRequestOperation *)operation
                   forFetchRequest:(NSFetchRequest *)fetchRequest
                    fetchedObjects:(NSArray *)fetchedObjects
{
    NSString *notificationName = [operation isFinished] ? AFIncrementalStoreContextDidFetchRemoteValues : AFIncrementalStoreContextWillFetchRemoteValues;
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:operation forKey:AFIncrementalStoreRequestOperationKey];
    [userInfo setObject:fetchRequest forKey:AFIncrementalStorePersistentStoreRequestKey];
    if ([operation isFinished] && fetchedObjects) {
        [userInfo setObject:fetchedObjects forKey:AFIncrementalStoreFetchedObjectsKey];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
            aboutRequestOperations:(NSArray *)operations
             forSaveChangesRequest:(NSSaveChangesRequest *)saveChangesRequest
{
    NSString *notificationName = [[operations lastObject] isFinished] ? AFIncrementalStoreContextDidSaveRemoteValues : AFIncrementalStoreContextWillSaveRemoteValues;
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:operations forKey:AFIncrementalStoreRequestOperationKey];
    [userInfo setObject:saveChangesRequest forKey:AFIncrementalStorePersistentStoreRequestKey];

    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

#pragma mark -

- (NSManagedObjectContext *)backingManagedObjectContext {
    if (!_backingManagedObjectContext) {
        _backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        _backingManagedObjectContext.persistentStoreCoordinator = _backingPersistentStoreCoordinator;
        _backingManagedObjectContext.retainsRegisteredObjects = YES;
    }
    
    return _backingManagedObjectContext;
}

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    NSManagedObjectID *objectID = nil;
    NSMutableDictionary *objectIDsByResourceIdentifier = [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:entity.name];
    if (objectIDsByResourceIdentifier) {
        objectID = [objectIDsByResourceIdentifier objectForKey:resourceIdentifier];
    }
        
    if (!objectID) {
        objectID = [self newObjectIDForEntity:entity referenceObject:AFReferenceObjectFromResourceIdentifier(resourceIdentifier)];
    }
    
    NSParameterAssert([objectID.entity.name isEqualToString:entity.name]);
    
    return objectID;
}

- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[entity name]];
    fetchRequest.resultType = NSManagedObjectIDResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@", kAFIncrementalStoreResourceIdentifierAttributeName, resourceIdentifier];
    
    __block NSArray *results = nil;
    __block NSError *error = nil;
    
    [self.backingPersistentStoreCoordinator lock];
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
    [backingContext performBlockAndWait:^{
        results = [backingContext executeFetchRequest:fetchRequest error:&error];
    }];
    [self.backingPersistentStoreCoordinator unlock];
    
    if (error) {
        NSLog(@"Error: %@", error);
        return nil;
    }
    
    return [results lastObject];
}

- (void)updateBackingObject:(NSManagedObject *)backingObject
withAttributeAndRelationshipValuesFromManagedObject:(NSManagedObject *)managedObject
{
    for (NSRelationshipDescription *relationship in [managedObject.entity.relationshipsByName allValues]) {
        id relationshipValue = [managedObject valueForKey:relationship.name];
        if (!relationshipValue) {
            continue;
        }
        
        if ([relationship isToMany]) {
            id mutableBackingRelationshipValue = nil;
            if ([relationship isOrdered]) {
                mutableBackingRelationshipValue = [NSMutableOrderedSet orderedSetWithCapacity:[relationshipValue count]];
            } else {
                mutableBackingRelationshipValue = [NSMutableSet setWithCapacity:[relationshipValue count]];
            }
            
            for (NSManagedObject *relationshipManagedObject in relationshipValue) {
				if (![[relationshipManagedObject objectID] isTemporaryID]) {
					NSManagedObjectID *backingRelationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:relationshipManagedObject.objectID])];
					if (backingRelationshipObjectID) {
						NSManagedObject *backingRelationshipObject = [backingObject.managedObjectContext existingObjectWithID:backingRelationshipObjectID error:nil];
						if (backingRelationshipObject) {
							[mutableBackingRelationshipValue addObject:backingRelationshipObject];
						}
					}
				}
            }
            
            [backingObject setValue:mutableBackingRelationshipValue forKey:relationship.name];
        } else {
			if (![[relationshipValue objectID] isTemporaryID]) {
				NSManagedObjectID *backingRelationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:[relationshipValue objectID]])];
				if (backingRelationshipObjectID) {
					NSManagedObject *backingRelationshipObject = [backingObject.managedObjectContext existingObjectWithID:backingRelationshipObjectID error:nil];
					[backingObject setValue:backingRelationshipObject forKey:relationship.name];
				}
			}
        }
    }
    
    [backingObject setValuesForKeysWithDictionary:[managedObject dictionaryWithValuesForKeys:[managedObject.entity.attributesByName allKeys]]];
}

#pragma mark -

- (BOOL)insertOrUpdateObjectsFromRepresentations:(id)representationOrArrayOfRepresentations
                                        ofEntity:(NSEntityDescription *)defaultEntity
                                    fromResponse:(NSHTTPURLResponse *)response
                                           error:(NSError *__autoreleasing *)error
                                 completionBlock:(void (^)(NSArray *backingObjects))completionBlock
{
    NSParameterAssert([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]] || [representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]);
    
    if ([representationOrArrayOfRepresentations count] == 0) {
        if (completionBlock) {
            completionBlock([NSArray array]);
        }
        
        return NO;
    }
    
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
    NSString *lastModified = [[response allHeaderFields] valueForKey:@"Last-Modified"];

    NSArray *representations = nil;
    if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
        representations = representationOrArrayOfRepresentations;
    } else if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
        representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
    }

    NSUInteger numberOfRepresentations = [representations count];
    NSMutableArray *mutableManagedObjects = [NSMutableArray arrayWithCapacity:numberOfRepresentations];
    NSMutableArray *mutableBackingObjects = [NSMutableArray arrayWithCapacity:numberOfRepresentations];
    
    for (NSDictionary *representation in representations) {
        NSEntityDescription *entity = defaultEntity;
        if ([self.HTTPClient respondsToSelector:@selector(entityForRepresentation:suggestEntity:)]) {
            entity = [self.HTTPClient entityForRepresentation:representation suggestEntity:defaultEntity];
        }
        NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:response];
        NSAssert(resourceIdentifier, @"Resource Identifier Must not be nil");
        NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:entity withResourceIdentifier:resourceIdentifier];
        
        __block NSManagedObject *backingObject = nil;
        [backingContext performBlockAndWait:^{
            if (backingObjectID) {
                backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
            } else {
                backingObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:backingContext];
                [backingObject.managedObjectContext obtainPermanentIDsForObjects:[NSArray arrayWithObject:backingObject] error:nil];
            }
        }];
        
        NSDictionary *attributes = [self.HTTPClient attributesForRepresentation:representation ofEntity:entity fromResponse:response];
        [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
        [backingObject setValue:lastModified forKey:kAFIncrementalStoreLastModifiedAttributeName];
        [backingObject setValuesForKeysWithDictionary:attributes];
        
        NSDictionary *relationshipRepresentations = [self.HTTPClient representationsForRelationshipsFromRepresentation:representation ofEntity:entity fromResponse:response];
        for (NSString *relationshipName in relationshipRepresentations) {
            NSRelationshipDescription *relationship = [[entity relationshipsByName] valueForKey:relationshipName];
            id relationshipRepresentation = [relationshipRepresentations objectForKey:relationshipName];
            if (!relationship || (relationship.isOptional && (!relationshipRepresentation || [relationshipRepresentation isEqual:[NSNull null]]))) {
                continue;
            }
                        
            if (!relationshipRepresentation || [relationshipRepresentation isEqual:[NSNull null]] || [relationshipRepresentation count] == 0) {
                [backingObject setValue:nil forKey:relationshipName];
                continue;
            }
            
            [self insertOrUpdateObjectsFromRepresentations:relationshipRepresentation ofEntity:relationship.destinationEntity fromResponse:response error:error completionBlock:^(NSArray *backingObjects) {
                if ([relationship isToMany]) {
                    if ([relationship isOrdered]) {
                        [backingObject setValue:[NSOrderedSet orderedSetWithArray:backingObjects] forKey:relationship.name];
                    } else {
                        [backingObject setValue:[NSSet setWithArray:backingObjects] forKey:relationship.name];
                    }
                } else {
                    [backingObject setValue:[backingObjects lastObject] forKey:relationship.name];
                }
            }];
        }
        [mutableBackingObjects addObject:backingObject];
    }
    
    if (completionBlock) {
        completionBlock(mutableBackingObjects);
    }

    return YES;
}

- (id)executeFetchRequest:(NSFetchRequest *)fetchRequest
              withContext:(NSManagedObjectContext *)context
                    error:(NSError *__autoreleasing *)error
{
    NSURLRequest *request = [self.HTTPClient requestForFetchRequest:fetchRequest withContext:context];
    if ([request URL]) {
        AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
            id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
            
            [self insertOrUpdateObjectsFromRepresentations:representationOrArrayOfRepresentations ofEntity:fetchRequest.entity fromResponse:operation.response error:error completionBlock:^(NSArray *backingObjects) {
                
                if (![[self backingManagedObjectContext] save:error]) {
                    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[*error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:*error forKey:NSUnderlyingErrorKey]];
                }
                
                NSMutableArray *fetchedObjects = [[NSMutableArray alloc] initWithCapacity:[backingObjects count]];
                [context performBlockAndWait:^{
                    for (NSManagedObject *backingObject in backingObjects) {
                        NSString *resourceIdentifier = [backingObject valueForKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                        // WARNING: backingObject.entity is modified and therefore not the same as original entity description.
                        // If we ever somehow created an new object ID this could be a problem.
                        NSManagedObjectID *objectID = [self objectIDForEntity:backingObject.entity withResourceIdentifier:resourceIdentifier];
                        NSManagedObject *managedObject = [context existingObjectWithID:objectID error:NULL];
                        if (managedObject) {
                            if (!managedObject.isFault) {
                                [context refreshObject:managedObject mergeChanges:NO];
                                [managedObject willAccessValueForKey:nil];
                            }
                            [fetchedObjects addObject:managedObject];
                        }
                    }
                }];
                
                [fetchedObjects sortUsingDescriptors:fetchRequest.sortDescriptors];
                
                [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjects:fetchedObjects];
            }];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            NSLog(@"Error: %@", error);
            [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjects:nil];
        }];

        [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjects:nil];
        [self.HTTPClient enqueueHTTPRequestOperation:operation];
    }
    
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
	NSFetchRequest *backingFetchRequest = [fetchRequest copy];
	backingFetchRequest.entity = [NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:backingContext];

    switch (fetchRequest.resultType) {
        case NSManagedObjectIDResultType:
        case NSManagedObjectResultType: {
            backingFetchRequest.resultType = NSManagedObjectIDResultType;
            
            NSArray *backingObjectIDs = [backingContext executeFetchRequest:backingFetchRequest error:error];
            NSMutableArray *mutableResults = [NSMutableArray arrayWithCapacity:[backingObjectIDs count]];
            
            for (NSManagedObjectID *backingObjectID in backingObjectIDs) {
                NSManagedObject *backingObject = [backingContext objectWithID:backingObjectID];
                NSString *resourceID = [backingObject valueForKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                NSManagedObjectID *objectID = [self objectIDForEntity:backingObject.entity withResourceIdentifier:resourceID];

                if (fetchRequest.resultType == NSManagedObjectIDResultType) {
                    [mutableResults addObject:objectID];
                } else {
                    NSManagedObject *object = [context objectWithID:objectID];
                    object.af_resourceIdentifier = resourceID;
                    [mutableResults addObject:object];
                }
            }
            
            return mutableResults;
        }
        case NSDictionaryResultType:
        case NSCountResultType:
            return [backingContext executeFetchRequest:backingFetchRequest error:error];
        default:
            return nil;
    }
}

- (id)executeSaveChangesRequest:(NSSaveChangesRequest *)saveChangesRequest
                    withContext:(NSManagedObjectContext *)context
                          error:(NSError *__autoreleasing *)error
{
    NSMutableArray *mutableOperations = [NSMutableArray array];
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];

    if ([self.HTTPClient respondsToSelector:@selector(requestForInsertedObject:)]) {
        for (NSManagedObject *insertedObject in [saveChangesRequest insertedObjects]) {
            NSURLRequest *request = [self.HTTPClient requestForInsertedObject:insertedObject];
            if (!request) {
                [backingContext performBlockAndWait:^{
                    CFUUIDRef UUID = CFUUIDCreate(NULL);
                    NSString *resourceIdentifier = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, UUID);
                    CFRelease(UUID);
                    
                    NSManagedObject *backingObject = [NSEntityDescription insertNewObjectForEntityForName:insertedObject.entity.name inManagedObjectContext:backingContext];
                    [backingObject.managedObjectContext obtainPermanentIDsForObjects:[NSArray arrayWithObject:backingObject] error:nil];
                    [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                    [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                    [backingContext save:nil];
                }];
                
                [insertedObject willChangeValueForKey:@"objectID"];
                [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                [insertedObject didChangeValueForKey:@"objectID"];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representation = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:[insertedObject entity] fromResponse:operation.response];
                NSManagedObjectID *objectID = [self objectIDForEntity:[insertedObject entity] withResourceIdentifier:resourceIdentifier];
                insertedObject.af_resourceIdentifier = resourceIdentifier;
                [insertedObject setValuesForKeysWithDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:insertedObject.entity fromResponse:operation.response]];
                
                [backingContext performBlockAndWait:^{
                    __block NSManagedObject *backingObject = nil;
                    if (objectID) {
                        [backingContext performBlockAndWait:^{
                            backingObject = [backingContext existingObjectWithID:objectID error:nil];
                        }];
                    }
                    
                    if (!backingObject) {
                        backingObject = [NSEntityDescription insertNewObjectForEntityForName:insertedObject.entity.name inManagedObjectContext:backingContext];
                        [backingObject.managedObjectContext obtainPermanentIDsForObjects:[NSArray arrayWithObject:backingObject] error:nil];
                    }
                    
                    [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                    [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                    [backingContext save:nil];
                }];
                
                [insertedObject willChangeValueForKey:@"objectID"];
                [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                [insertedObject didChangeValueForKey:@"objectID"];
                
                if (!insertedObject.isFault) {
                    [context refreshObject:insertedObject mergeChanges:NO];
                    [insertedObject willAccessValueForKey:nil];
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Insert Error: %@", error);
            }];
            NSLog(@"INSERT %@+%@", insertedObject.entity.name, insertedObject.af_resourceIdentifier);
            [mutableOperations addObject:operation];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForUpdatedObject:)]) {
        for (NSManagedObject *updatedObject in [saveChangesRequest updatedObjects]) {
            NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[updatedObject entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:updatedObject.objectID])];

            NSURLRequest *request = [self.HTTPClient requestForUpdatedObject:updatedObject];
            if (!request) {
                [backingContext performBlockAndWait:^{
                    NSManagedObject *backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
                    [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:updatedObject];
                    [backingContext save:nil];
                }];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representation = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                [updatedObject setValuesForKeysWithDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:updatedObject.entity fromResponse:operation.response]];
                
                [backingContext performBlockAndWait:^{
                    NSManagedObject *backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
                    [self updateBackingObject:backingObject withAttributeAndRelationshipValuesFromManagedObject:updatedObject];
                    [backingContext save:nil];
                }];
                if (!updatedObject.isFault) {
                    [context refreshObject:updatedObject mergeChanges:NO];
                    [updatedObject willAccessValueForKey:nil];
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Update Error: %@", error);
                if (!updatedObject.isFault) {
                    [context refreshObject:updatedObject mergeChanges:NO];
                    [updatedObject willAccessValueForKey:nil];
                }
            }];
            NSLog(@"UPDATE %@+%@", updatedObject.entity.name, updatedObject.af_resourceIdentifier);
            [mutableOperations addObject:operation];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForDeletedObject:)]) {
        for (NSManagedObject *deletedObject in [saveChangesRequest deletedObjects]) {
            NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[deletedObject entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:deletedObject.objectID])];

            NSURLRequest *request = [self.HTTPClient requestForDeletedObject:deletedObject];
            if (!request) {
                [backingContext performBlockAndWait:^{
                    NSManagedObject *backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
                    [backingContext deleteObject:backingObject];
                    [backingContext save:nil];
                }];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                [backingContext performBlockAndWait:^{
                    NSManagedObject *backingObject = [backingContext existingObjectWithID:backingObjectID error:nil];
                    [backingContext deleteObject:backingObject];
                    [backingContext save:nil];
                }];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Delete Error: %@", error);
            }];
            NSLog(@"DELETE %@+%@", deletedObject.entity.name, deletedObject.af_resourceIdentifier);
            [mutableOperations addObject:operation];
        }
    }
    
    // NSManagedObjectContext removes object references from an NSSaveChangesRequest as each object is saved, so create a copy of the original in order to send useful information in AFIncrementalStoreContextDidSaveRemoteValues notification.
    NSSaveChangesRequest *saveChangesRequestCopy = [[NSSaveChangesRequest alloc] initWithInsertedObjects:[saveChangesRequest.insertedObjects copy] updatedObjects:[saveChangesRequest.updatedObjects copy] deletedObjects:[saveChangesRequest.deletedObjects copy] lockedObjects:[saveChangesRequest.lockedObjects copy]];
    
    [self notifyManagedObjectContext:context aboutRequestOperations:mutableOperations forSaveChangesRequest:saveChangesRequestCopy];

    [self.HTTPClient enqueueBatchOfHTTPRequestOperations:mutableOperations progressBlock:nil completionBlock:^(NSArray *operations) {
        [self notifyManagedObjectContext:context aboutRequestOperations:operations forSaveChangesRequest:saveChangesRequestCopy];
    }];
    
    return [NSArray array];
}

#pragma mark - NSIncrementalStore

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    if (!_backingObjectIDByObjectID) {
        NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
        [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString] forKey:NSStoreUUIDKey];
        [mutableMetadata setValue:NSStringFromClass([self class]) forKey:NSStoreTypeKey];
        [self setMetadata:mutableMetadata];
        
        _backingObjectIDByObjectID = [[NSCache alloc] init];
        _registeredObjectIDsByEntityNameAndNestedResourceIdentifier = [[NSMutableDictionary alloc] init];
        _refreshingRelationships = [[NSMutableSet alloc] init];
        _refreshingObjects = [[NSMutableSet alloc] init];
        
        NSManagedObjectModel *model = [self.persistentStoreCoordinator.managedObjectModel copy];
        for (NSEntityDescription *entity in model.entities) {
            // Don't add properties for sub-entities, as they already exist in the super-entity
            if ([entity superentity]) {
                continue;
            }
            
            NSAttributeDescription *resourceIdentifierProperty = [[NSAttributeDescription alloc] init];
            [resourceIdentifierProperty setName:kAFIncrementalStoreResourceIdentifierAttributeName];
            [resourceIdentifierProperty setAttributeType:NSStringAttributeType];
            [resourceIdentifierProperty setIndexed:YES];
            
            NSAttributeDescription *lastModifiedProperty = [[NSAttributeDescription alloc] init];
            [lastModifiedProperty setName:kAFIncrementalStoreLastModifiedAttributeName];
            [lastModifiedProperty setAttributeType:NSStringAttributeType];
            [lastModifiedProperty setIndexed:NO];
            
            [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:[NSArray arrayWithObjects:resourceIdentifierProperty, lastModifiedProperty, nil]]];
        }
        
        _backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        
        return YES;
    } else {
        return NO;
    }
}

- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error {
    NSMutableArray *mutablePermanentIDs = [NSMutableArray arrayWithCapacity:[array count]];
    for (NSManagedObject *managedObject in array) {
        NSManagedObjectID *managedObjectID = managedObject.objectID;
        if ([managedObjectID isTemporaryID] && managedObject.af_resourceIdentifier) {
            NSManagedObjectID *objectID = [self objectIDForEntity:managedObject.entity withResourceIdentifier:managedObject.af_resourceIdentifier];
            [mutablePermanentIDs addObject:objectID];
        } else {
            [mutablePermanentIDs addObject:managedObjectID];
        }
    }
    
    return mutablePermanentIDs;
}

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error
{
    if (persistentStoreRequest.requestType == NSFetchRequestType) {
        return [self executeFetchRequest:(NSFetchRequest *)persistentStoreRequest withContext:context error:error];
    } else if (persistentStoreRequest.requestType == NSSaveRequestType) {
        return [self executeSaveChangesRequest:(NSSaveChangesRequest *)persistentStoreRequest withContext:context error:error];
    } else {
        NSMutableDictionary *mutableUserInfo = [NSMutableDictionary dictionary];
        [mutableUserInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Unsupported NSFetchRequestResultType, %d", nil), persistentStoreRequest.requestType] forKey:NSLocalizedDescriptionKey];
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:0 userInfo:mutableUserInfo];
        }
        
        return nil;
    }
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError *__autoreleasing *)error
{
    NSAssert([NSThread isMainThread], @"Method is not yet thread safe");
    NSString *resourceIdentifier = AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID]);
    NSString *requestHash = [NSString stringWithFormat:@"%@+%@", objectID.entity.name, resourceIdentifier];
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[[objectID entity] name]];
    fetchRequest.resultType = NSDictionaryResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.includesSubentities = NO;
    fetchRequest.propertiesToFetch = [[[[NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:context] attributesByName] allKeys] arrayByAddingObject:kAFIncrementalStoreLastModifiedAttributeName];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@", kAFIncrementalStoreResourceIdentifierAttributeName, AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
    
    __block NSArray *results;
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
    [backingContext performBlockAndWait:^{
        results = [backingContext executeFetchRequest:fetchRequest error:error];
    }];
    
    NSDictionary *attributeValues = [results lastObject] ?: [NSDictionary dictionary];
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:attributeValues version:1];
    

    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteAttributeValuesForObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteAttributeValuesForObjectWithID:objectID inManagedObjectContext:context]) {
        if (attributeValues) {
            NSMutableURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForObjectWithID:objectID withContext:context];
            NSString *lastModified = [attributeValues objectForKey:kAFIncrementalStoreLastModifiedAttributeName];
            if (lastModified) {
                [request setValue:lastModified forHTTPHeaderField:@"Last-Modified"];
            }
            
            if ([request URL]) {
                if ([attributeValues valueForKey:kAFIncrementalStoreLastModifiedAttributeName]) {
                    [request setValue:[[attributeValues valueForKey:kAFIncrementalStoreLastModifiedAttributeName] description] forHTTPHeaderField:@"If-Modified-Since"];
                }
                
                AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, NSDictionary *representation) {

                    
                    NSMutableDictionary *mutableAttributeValues = [attributeValues mutableCopy];
                    [mutableAttributeValues addEntriesFromDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:objectID.entity fromResponse:operation.response]];
                    [mutableAttributeValues removeObjectForKey:kAFIncrementalStoreLastModifiedAttributeName];
                    
                    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
                    NSManagedObject *backingObject = [[self backingManagedObjectContext] existingObjectWithID:backingObjectID error:nil];
                    [backingObject setValuesForKeysWithDictionary:mutableAttributeValues];
                    
                    NSString *lastModified = [[operation.response allHeaderFields] valueForKey:@"Last-Modified"];
                    if (lastModified) {
                        [backingObject setValue:lastModified forKey:kAFIncrementalStoreLastModifiedAttributeName];
                    }

                    if (![[self backingManagedObjectContext] save:error]) {
                        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[*error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:*error forKey:NSUnderlyingErrorKey]];
                    }
                    [context performBlockAndWait:^{
                        NSManagedObject *managedObject = [context existingObjectWithID:objectID error:error];
                        if (!managedObject.isFault) {
                            [context refreshObject:managedObject mergeChanges:NO];
                            [managedObject willAccessValueForKey:nil];
                        }
                    }];
                    [_refreshingObjects performSelector:@selector(removeObject:) withObject:requestHash afterDelay:AFDelta];
                    NSLog(@"Remotely fulfill object %@", requestHash);
                } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                    [_refreshingObjects performSelector:@selector(removeObject:) withObject:requestHash afterDelay:AFDelta];
                    NSLog(@"Error: %@, %@", operation, error);
                }];
                [_refreshingObjects addObject:requestHash];
                [self.HTTPClient enqueueHTTPRequestOperation:operation];
                NSLog(@"Request remote object %@", requestHash);
            }
        }
    }
    NSLog(@"Locally fulfill object  %@", requestHash);
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError *__autoreleasing *)error
{
    NSAssert([NSThread isMainThread], @"Method is not yet thread safe");
    NSString *resourceIdentifier = AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID]);
    NSString *requestHash = [NSString stringWithFormat:@"%@+%@+%@", objectID.entity.name, resourceIdentifier, relationship.name];
    
//    NSLog(@"Received relationship request %@", requestHash);
    NSManagedObject *managedObject = [context existingObjectWithID:objectID error:NULL];

    if (!managedObject.isDeleted && ![_refreshingRelationships containsObject:requestHash] && [self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteValuesForRelationship:forObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteValuesForRelationship:relationship forObjectWithID:objectID inManagedObjectContext:context]) {
        NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForRelationship:relationship forObjectWithID:objectID withContext:context];
        
        if ([request URL]) {
            NSLog(@"Requesting remote relationship %@", requestHash);
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                [self insertOrUpdateObjectsFromRepresentations:representationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:operation.response error:error completionBlock:^(NSArray *backingObjects) {
                    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:objectID.entity withResourceIdentifier:resourceIdentifier];
                    NSManagedObject *backingObject = [[self backingManagedObjectContext] existingObjectWithID:backingObjectID error:nil];
                    
                    if ([relationship isToMany]) {
                        if ([relationship isOrdered]) {
                            [backingObject setValue:[NSOrderedSet orderedSetWithArray:backingObjects] forKey:relationship.name];
                        } else {
                            [backingObject setValue:[NSSet setWithArray:backingObjects] forKey:relationship.name];
                        }
                    } else {
                        [backingObject setValue:[backingObjects lastObject] forKey:relationship.name];
                    }
                    
                    if (![[self backingManagedObjectContext] save:error]) {
                        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[*error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:*error forKey:NSUnderlyingErrorKey]];
                    }
                    NSLog(@"Remotely fulfill relationship  %@", requestHash);
                    [context performBlockAndWait:^{
                        NSManagedObject *managedObject = [context existingObjectWithID:objectID error:NULL];
                        if (!managedObject.isFault) {
                            [context refreshObject:managedObject mergeChanges:NO];
                            [managedObject willAccessValueForKey:nil];
                        }
                    }];
                    // TODO: FIX potential race conditions when not on main thread.
                    [_refreshingRelationships performSelector:@selector(removeObject:) withObject:requestHash afterDelay:AFDelta];
                }];
                
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                [_refreshingRelationships performSelector:@selector(removeObject:) withObject:requestHash afterDelay:AFDelta];
                NSLog(@"Error: %@, %@", operation, error);
            }];
            [_refreshingRelationships addObject:requestHash];
            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
    }
    NSLog(@"Locally fulfill relationship   %@", requestHash);
    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
    NSManagedObject *backingObject = (backingObjectID == nil) ? nil : [[self backingManagedObjectContext] existingObjectWithID:backingObjectID error:nil];
    
    if (backingObject && ![backingObject hasChanges]) {
        id backingRelationshipObject = [backingObject valueForKeyPath:relationship.name];
        if ([relationship isToMany]) {
            NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[backingRelationshipObject count]];
            for (NSManagedObject *backingDestObject in backingRelationshipObject) {
                NSString *resourceIdentifier = [backingDestObject valueForKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                NSManagedObjectID *objectID = [self objectIDForEntity:backingDestObject.entity withResourceIdentifier:resourceIdentifier];
                [mutableObjects addObject:objectID];
            }
            return mutableObjects;            
        } else {
            NSString *resourceIdentifier = [backingRelationshipObject valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName];
            NSManagedObjectID *objectID = [self objectIDForEntity:[backingRelationshipObject entity] withResourceIdentifier:resourceIdentifier];
            
            return objectID ?: [NSNull null];
        }
    } else {
        if ([relationship isToMany]) {
            return [NSArray array];
        } else {
            return [NSNull null];
        }
    }
}

- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        id referenceObject = [self referenceObjectForObjectID:objectID];
        if (!referenceObject) {
            continue;
        }
        
        NSMutableDictionary *objectIDsByResourceIdentifier = [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:objectID.entity.name] ?: [NSMutableDictionary dictionary];
        [objectIDsByResourceIdentifier setObject:objectID forKey:AFResourceIdentifierFromReferenceObject(referenceObject)];
        
        [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier setObject:objectIDsByResourceIdentifier forKey:objectID.entity.name];
    }
}

- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        [[_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:objectID.entity.name] removeObjectForKey:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
    }
}

@end
